CREATE PROCEDURE dbo.sp_NextFreeSlotsDatamart
    @SlotMinutes         INT = NULL,   -- optional minimum-duration filter, same semantics as sp_GetNextFreeSlots
    @StaleDaysThreshold   INT = 180    -- days since last real visit before PossiblyDeparted flips to 1; tune per leave policy
                                        -- (6mo default -- consider longer given "boomerang" providers)
                                        -- This is the SINGLE source of truth for staleness in the pipeline --
                                        -- dbo.vw_ActiveSchedulingProviders deliberately does not duplicate this logic.
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now     DATETIME2(0) = CAST(GETDATE() AS DATETIME2(0));
    DECLARE @BuiltAt DATETIME2(0) = SYSDATETIME();

    --------------------------------------------------------------------
    -- 0) Last real visit per provider, joined by ID (not name -- avoids
    --    the fragile name-matching #Busy used to rely on)
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#LastVisit') IS NOT NULL DROP TABLE #LastVisit;
    SELECT
        vib.prov_key_MQ AS Staff_Staff_ID,
        LastVisitDate = MAX(CAST(vib.appt_dt AS DATE))
    INTO #LastVisit
    FROM dbo.visits_in_buckets vib
    GROUP BY vib.prov_key_MQ;

    --------------------------------------------------------------------
    -- 1) All providers' FREE_SLOT windows, future only, optionally
    --    filtered to a minimum duration.
    --    ADDED: gated to only in-scope providers via
    --    vw_ActiveSchedulingProviders, so out-of-scope rows (the
    --    Infusion suite placeholder, machine resources, non-Physician/APP
    --    buckets, inactive/duplicate provider rows) never generate
    --    "free slot" output in the datamart, regardless of what
    --    ProviderEffectiveSchedule happens to contain for them.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#FreeIntervals') IS NOT NULL DROP TABLE #FreeIntervals;
    SELECT pes.*
    INTO #FreeIntervals
    FROM dbo.ProviderEffectiveSchedule pes
    JOIN dbo.vw_ActiveSchedulingProviders asp
        ON asp.Staff_Staff_ID = pes.Staff_Staff_ID
    WHERE pes.Block_Type = 'FREE_SLOT'
      AND pes.StartDatetime >= @Now
      AND (@SlotMinutes IS NULL OR DATEDIFF(MINUTE, pes.StartDatetime, pes.EndDatetime) >= @SlotMinutes);

    --------------------------------------------------------------------
    -- 2) All real booked appointments (all providers)
    --    FIXED: vw_ScheduleNormalized now exposes Staff_Staff_ID
    --    directly (it already had the ID during its own join, it just
    --    wasn't surfaced before). This removes the name-matching
    --    round-trip that used to re-derive the ID from vsn.Provider by
    --    joining back to visit_providers_in_buckets on prov_name_MQ --
    --    that re-join is gone entirely now.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Busy') IS NOT NULL DROP TABLE #Busy;
    SELECT
        vsn.Staff_Staff_ID,
        vsn.StartDatetime, vsn.EndDatetime
    INTO #Busy
    FROM dbo.vw_ScheduleNormalized vsn;
    CREATE INDEX IX_Busy_Staff ON #Busy (Staff_Staff_ID);

    --------------------------------------------------------------------
    -- 3) Booked count per whole window, plus EffectiveCapacity derived
    --    per the confirmed precedence (see template_capacity_triage.sql):
    --      1. RuleLimit >= 1                 -> use as-is
    --      2. Manual override (capacity)     -> use it
    --      3. Manual override (duration)     -> window / duration
    --      4. Clean single parsed duration   -> window / duration
    --      5. Explicit "Max N" text parsed   -> use N
    --      6. Otherwise                      -> NULL (unlimited)
    --    CapacitySource is carried along for auditability/debugging --
    --    lets you see WHY a given window got the limit it did.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#FreeIntervalBookedCount') IS NOT NULL DROP TABLE #FreeIntervalBookedCount;
    SELECT
        f.Staff_Staff_ID, f.Provider, f.TemplatePK, f.Activity, f.TemplRule, f.RuleLimit,
        f.StartDatetime, f.EndDatetime,
        BookedCount = (
            SELECT COUNT(*)
            FROM #Busy b
            WHERE b.Staff_Staff_ID = f.Staff_Staff_ID
              AND b.StartDatetime < f.EndDatetime
              AND b.EndDatetime   > f.StartDatetime
        ),
        EffectiveCapacity = CASE
            WHEN f.RuleLimit >= 1 THEN f.RuleLimit
            WHEN ovr.ManualCapacity IS NOT NULL THEN ovr.ManualCapacity
            WHEN ovr.ManualDurationMinutes IS NOT NULL
                THEN DATEDIFF(MINUTE, f.StartDatetime, f.EndDatetime) / ovr.ManualDurationMinutes
            WHEN dbo.fn_ExtractDurationMinutes(f.Activity) IS NOT NULL
                THEN DATEDIFF(MINUTE, f.StartDatetime, f.EndDatetime) / dbo.fn_ExtractDurationMinutes(f.Activity)
            WHEN dbo.fn_ExtractMaxPatients(f.Activity) IS NOT NULL
                THEN dbo.fn_ExtractMaxPatients(f.Activity)
            ELSE NULL
        END,
        CapacitySource = CASE
            WHEN f.RuleLimit >= 1 THEN 'RULELIMIT'
            WHEN ovr.ManualCapacity IS NOT NULL THEN 'MANUAL_OVERRIDE_CAPACITY'
            WHEN ovr.ManualDurationMinutes IS NOT NULL THEN 'MANUAL_OVERRIDE_DURATION'
            WHEN dbo.fn_ExtractDurationMinutes(f.Activity) IS NOT NULL THEN 'DURATION_DERIVED'
            WHEN dbo.fn_ExtractMaxPatients(f.Activity) IS NOT NULL THEN 'MAX_PARSED'
            ELSE 'UNLIMITED'
        END
    INTO #FreeIntervalBookedCount
    FROM #FreeIntervals f
    LEFT JOIN dbo.TemplateCapacityOverride ovr
        ON ovr.TemplateDescription = f.Activity;

    --------------------------------------------------------------------
    -- 4) Eligible = under EffectiveCapacity (or no cap applies).
    --    SCOPE CHANGE: enforcement now applies to TemplRule IN (1, 2, 12)
    --    -- broadened from TemplRule = 2 only, per the earlier confirmed
    --    decision that all three carry real limits (RuleLimit enforcement
    --    must apply regardless of TemplRule value). TemplRule = 9 ("Only
    --    Appointments with This Activity") is deliberately excluded --
    --    RuleLimit is documented as unused for that rule, and activity-
    --    restriction enforcement for 9/12 remains a separate deferred item.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Eligible') IS NOT NULL DROP TABLE #Eligible;
    SELECT
        Staff_Staff_ID, Provider, TemplatePK, Activity, TemplRule, RuleLimit,
        EffectiveCapacity, CapacitySource, BookedCount,
        StartDatetime, EndDatetime,
        OpenCapacity = CASE WHEN EffectiveCapacity IS NOT NULL
                            THEN EffectiveCapacity - BookedCount
                            ELSE NULL END,
        RuleName = CASE TemplRule
                        WHEN 1  THEN 'Maximum Conflicts'
                        WHEN 2  THEN 'Maximum Appointments'
                        WHEN 9  THEN 'Only Appointments with This Activity'
                        WHEN 12 THEN 'Maximum Appointments With This Activity'
                        WHEN 5  THEN 'Maximum Appointments of Status'
                        WHEN 7  THEN 'Only Patients of Status'
                        ELSE 'Unspecified'
                   END
    INTO #Eligible
    FROM #FreeIntervalBookedCount
    WHERE TemplRule NOT IN (1, 2, 12)
       OR EffectiveCapacity IS NULL
       OR BookedCount < EffectiveCapacity;

    --------------------------------------------------------------------
    -- 5) Rank each provider's windows soonest-first
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Ranked') IS NOT NULL DROP TABLE #Ranked;
    SELECT
        *,
        SlotRank = ROW_NUMBER() OVER (PARTITION BY Staff_Staff_ID ORDER BY StartDatetime ASC)
    INTO #Ranked
    FROM #Eligible;

    --------------------------------------------------------------------
    -- 5b) Attach staleness signal -- NULL LastVisitDate means "no
    --     recorded visits at all" (could be a brand-new provider with
    --     no history yet, not necessarily departed) -- left unflagged
    --     rather than assumed departed, since there's no data either way.
    --     This remains the pipeline's ONLY staleness computation --
    --     vw_ActiveSchedulingProviders intentionally does not duplicate it.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#RankedWithVisit') IS NOT NULL DROP TABLE #RankedWithVisit;
    SELECT
        r.*,
        lv.LastVisitDate,
        DaysSinceLastVisit = CASE WHEN lv.LastVisitDate IS NOT NULL
                                   THEN DATEDIFF(DAY, lv.LastVisitDate, @Now)
                                   ELSE NULL END,
        PossiblyDeparted   = CASE WHEN lv.LastVisitDate IS NOT NULL
                                   AND DATEDIFF(DAY, lv.LastVisitDate, @Now) > @StaleDaysThreshold
                                   THEN 1 ELSE 0 END
    INTO #RankedWithVisit
    FROM #Ranked r
    LEFT JOIN #LastVisit lv ON lv.Staff_Staff_ID = r.Staff_Staff_ID;

    --------------------------------------------------------------------
    -- 6) Persist
    --------------------------------------------------------------------
    TRUNCATE TABLE dbo.NextFreeSlotsDatamart;

    INSERT INTO dbo.NextFreeSlotsDatamart
        (Staff_Staff_ID, Provider, TemplatePK, Activity, TemplRule, RuleName, RuleLimit,
         EffectiveCapacity, CapacitySource,
         BookedCount, OpenCapacity, StartDatetime, EndDatetime, SlotRank,
         LastVisitDate, DaysSinceLastVisit, PossiblyDeparted, BuiltAt)
    SELECT
        Staff_Staff_ID, Provider, TemplatePK, Activity, TemplRule, RuleName, RuleLimit,
        EffectiveCapacity, CapacitySource,
        BookedCount, OpenCapacity, StartDatetime, EndDatetime, SlotRank,
        LastVisitDate, DaysSinceLastVisit, PossiblyDeparted, @BuiltAt
    FROM #RankedWithVisit;
END
GO