USE MosaiqAdmin
GO
IF OBJECT_ID('dbo.sp_NextFreeSlotsDatamart', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_NextFreeSlotsDatamart;
GO

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
    -- 3) Booked count per whole window
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
        )
    INTO #FreeIntervalBookedCount
    FROM #FreeIntervals f;

    --------------------------------------------------------------------
    -- 4) Eligible = under the configured Max Appointments limit (or
    --    no cap applies / RuleLimit unconfigured)
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Eligible') IS NOT NULL DROP TABLE #Eligible;
    SELECT
        Staff_Staff_ID, Provider, TemplatePK, Activity, TemplRule, RuleLimit, BookedCount,
        StartDatetime, EndDatetime,
        OpenCapacity = CASE WHEN TemplRule = 2 AND ISNULL(RuleLimit, 0) > 0
                            THEN RuleLimit - BookedCount
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
    WHERE TemplRule <> 2
       OR RuleLimit IS NULL OR RuleLimit = 0
       OR BookedCount < RuleLimit;

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
         BookedCount, OpenCapacity, StartDatetime, EndDatetime, SlotRank,
         LastVisitDate, DaysSinceLastVisit, PossiblyDeparted, BuiltAt)
    SELECT
        Staff_Staff_ID, Provider, TemplatePK, Activity, TemplRule, RuleName, RuleLimit,
        BookedCount, OpenCapacity, StartDatetime, EndDatetime, SlotRank,
        LastVisitDate, DaysSinceLastVisit, PossiblyDeparted, @BuiltAt
    FROM #RankedWithVisit;
END
GO