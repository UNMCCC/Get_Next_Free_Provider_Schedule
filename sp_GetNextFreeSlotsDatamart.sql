USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_NextFreeSlotsDatamart]    Script Date: 9/8/2026 3:40:16 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [dbo].[sp_NextFreeSlotsDatamart]
    @SlotMinutes INT = NULL   -- optional minimum-duration filter, same semantics as sp_GetNextFreeSlots
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now      DATETIME2(0) = CAST(GETDATE() AS DATETIME2(0));
    DECLARE @BuiltAt  DATETIME2(0) = SYSDATETIME();

    --------------------------------------------------------------------
    -- 1) All providers' FREE_SLOT windows, future only, optionally
    --    filtered to a minimum duration
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#FreeIntervals') IS NOT NULL DROP TABLE #FreeIntervals;
    SELECT *
    INTO #FreeIntervals
    FROM dbo.ProviderEffectiveSchedule
    WHERE Block_Type = 'FREE_SLOT'
      AND StartDatetime >= @Now
      AND (@SlotMinutes IS NULL OR DATEDIFF(MINUTE, StartDatetime, EndDatetime) >= @SlotMinutes);

    --------------------------------------------------------------------
    -- 2) All real booked appointments (all providers)
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Busy') IS NOT NULL DROP TABLE #Busy;
    SELECT
        vpb.prov_key_MQ AS Staff_Staff_ID,
        vsn.StartDatetime, vsn.EndDatetime
    INTO #Busy
    FROM dbo.vw_ScheduleNormalized vsn
    JOIN dbo.visit_providers_in_buckets vpb ON vpb.prov_name_MQ = vsn.Provider;

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
    -- actually, Max Conflicts is also limiting: drop that restricting clause.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Eligible') IS NOT NULL DROP TABLE #Eligible;
    SELECT
        Staff_Staff_ID, Provider, TemplatePK, Activity, TemplRule, RuleLimit, BookedCount,
        StartDatetime, EndDatetime,
        OpenCapacity = CASE WHEN  -- TemplRule = 2 AND -- DROP this,  
                                ISNULL(RuleLimit, 0) > 0
                             THEN RuleLimit - BookedCount
                             ELSE NULL END,
        RuleName = CASE TemplRule
                       WHEN 1  THEN 'Maximum Conflicts'
                       WHEN 2  THEN 'Maximum Appointments'
                       WHEN 9  THEN 'Only Appointments with This Activity'
                       WHEN 12 THEN 'Maximum Appointments With This Activity'
                       WHEN 5  THEN 'Unknown (TemplRule=5)'
                       WHEN 7  THEN 'Unknown (TemplRule=7)'
                       ELSE 'Unspecified'
                   END
    INTO #Eligible
    FROM #FreeIntervalBookedCount
    WHERE -- TemplRule <> 2 OR -- drop cause other rules are also limiting.
       RuleLimit IS NULL OR RuleLimit = 0
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
    -- 6) Persist
    --------------------------------------------------------------------
    TRUNCATE TABLE dbo.NextFreeSlotsDatamart;

    INSERT INTO dbo.NextFreeSlotsDatamart
        (Staff_Staff_ID, Provider, TemplatePK, Activity, TemplRule, RuleName, RuleLimit,
         BookedCount, OpenCapacity, StartDatetime, EndDatetime, SlotRank, BuiltAt)
    SELECT
        Staff_Staff_ID, Provider, TemplatePK, Activity, TemplRule, RuleName, RuleLimit,
        BookedCount, OpenCapacity, StartDatetime, EndDatetime, SlotRank, @BuiltAt
    FROM #Ranked;

END
GO


