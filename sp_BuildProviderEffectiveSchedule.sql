USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_BuildProviderEffectiveSchedule]    Script Date: 9/10/2026 7:06:20 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [dbo].[sp_BuildProviderEffectiveSchedule]
AS
BEGIN
    SET NOCOUNT ON;

    --------------------------------------------------------------------
    -- 1) Boundaries: every distinct Start/End time per provider
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Boundaries') IS NOT NULL DROP TABLE #Boundaries;
    SELECT DISTINCT Staff_Staff_ID, BoundaryTime = StartDatetime
    INTO #Boundaries
    FROM dbo.TemplateOccurrencesExpanded;

    INSERT INTO #Boundaries (Staff_Staff_ID, BoundaryTime)
    SELECT DISTINCT Staff_Staff_ID, EndDatetime
    FROM dbo.TemplateOccurrencesExpanded;

    IF OBJECT_ID('tempdb..#BoundariesDistinct') IS NOT NULL DROP TABLE #BoundariesDistinct;
    SELECT DISTINCT Staff_Staff_ID, BoundaryTime
    INTO #BoundariesDistinct
    FROM #Boundaries;

    IF OBJECT_ID('tempdb..#BoundariesRanked') IS NOT NULL DROP TABLE #BoundariesRanked;
    SELECT
        *,
        rn = ROW_NUMBER() OVER (PARTITION BY Staff_Staff_ID ORDER BY BoundaryTime)
    INTO #BoundariesRanked
    FROM #BoundariesDistinct;

    --------------------------------------------------------------------
    -- 2) Elementary intervals: consecutive boundary pairs per provider
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Elementary') IS NOT NULL DROP TABLE #Elementary;
    SELECT
        a.Staff_Staff_ID,
        IntervalStart = a.BoundaryTime,
        IntervalEnd   = b.BoundaryTime
    INTO #Elementary
    FROM #BoundariesRanked a
    JOIN #BoundariesRanked b
        ON b.Staff_Staff_ID = a.Staff_Staff_ID
       AND b.rn = a.rn + 1
    WHERE b.BoundaryTime > a.BoundaryTime;

    --------------------------------------------------------------------
    -- 3) Which occurrences fully cover each elementary interval
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#ElementaryCovered') IS NOT NULL DROP TABLE #ElementaryCovered;
    SELECT
        e.Staff_Staff_ID, e.IntervalStart, e.IntervalEnd,
        t.TemplatePK,
        t.Activity, 
		t.TemplateType, 
		t.Block_Type, 
		t.Priority, 
		t.TemplRule, 
		t.RuleLimit
    INTO #ElementaryCovered
    FROM #Elementary e
    JOIN dbo.TemplateOccurrencesExpanded t
        ON t.Staff_Staff_ID = e.Staff_Staff_ID
       AND t.StartDatetime <= e.IntervalStart
       AND t.EndDatetime   >= e.IntervalEnd;

    --------------------------------------------------------------------
    -- 4) Pick the Priority winner per elementary interval
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#ElementaryRanked') IS NOT NULL DROP TABLE #ElementaryRanked;
    SELECT
        *,
        rn = ROW_NUMBER() OVER (
            PARTITION BY Staff_Staff_ID, IntervalStart, IntervalEnd
            ORDER BY
                Priority DESC,                                       -- higher Priority wins
                CASE WHEN Block_Type = 'BLOCKING' THEN 0 ELSE 1 END,  -- tie-break: BLOCKING wins ties
                TemplatePK ASC                                       -- final deterministic tiebreaker
        )
    INTO #ElementaryRanked
    FROM #ElementaryCovered;

    IF OBJECT_ID('tempdb..#ElementaryWinner') IS NOT NULL DROP TABLE #ElementaryWinner;
    SELECT *
    INTO #ElementaryWinner
    FROM #ElementaryRanked
    WHERE rn = 1;

    --------------------------------------------------------------------
    -- 5) Coalesce adjacent slivers with the same winning template back
    --    into single intervals (classic gaps-and-islands)
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#WinnerFlagged') IS NOT NULL DROP TABLE #WinnerFlagged;
    SELECT
        *,
        PrevEnd = LAG(IntervalEnd)   OVER (PARTITION BY Staff_Staff_ID ORDER BY IntervalStart),
        PrevPK  = LAG(TemplatePK)    OVER (PARTITION BY Staff_Staff_ID ORDER BY IntervalStart)
    INTO #WinnerFlagged
    FROM #ElementaryWinner;

    IF OBJECT_ID('tempdb..#WinnerGrouped') IS NOT NULL DROP TABLE #WinnerGrouped;
    SELECT
        *,
        IsNewGroup = CASE WHEN PrevEnd IS NULL OR PrevEnd <> IntervalStart OR PrevPK <> TemplatePK
                          THEN 1 ELSE 0 END
    INTO #WinnerGrouped
    FROM #WinnerFlagged;

    IF OBJECT_ID('tempdb..#WinnerGroupID') IS NOT NULL DROP TABLE #WinnerGroupID;
    SELECT
        *,
        GroupID = SUM(IsNewGroup) OVER (PARTITION BY Staff_Staff_ID ORDER BY IntervalStart ROWS UNBOUNDED PRECEDING)
    INTO #WinnerGroupID
    FROM #WinnerGrouped;

    IF OBJECT_ID('tempdb..#Coalesced') IS NOT NULL DROP TABLE #Coalesced;
    SELECT
        Staff_Staff_ID, GroupID, TemplatePK, Activity, TemplateType, Block_Type, Priority, TemplRule, RuleLimit,
        StartDatetime = MIN(IntervalStart),
        EndDatetime   = MAX(IntervalEnd)
    INTO #Coalesced
    FROM #WinnerGroupID
    GROUP BY Staff_Staff_ID, GroupID, TemplatePK, Activity, TemplateType, Block_Type, Priority, TemplRule, RuleLimit;

    --------------------------------------------------------------------
    -- 6) Persist, with provider name attached for readability
    --------------------------------------------------------------------
    TRUNCATE TABLE dbo.ProviderEffectiveSchedule;

    INSERT INTO dbo.ProviderEffectiveSchedule
        (Staff_Staff_ID, Provider, TemplatePK, Activity, TemplateType, Block_Type, Priority, TemplRule, RuleLimit, StartDatetime, EndDatetime)
    SELECT
        c.Staff_Staff_ID, vpb.prov_name_MQ, c.TemplatePK, c.Activity, c.TemplateType, c.Block_Type,
        c.Priority, c.TemplRule, c.RuleLimit, c.StartDatetime, c.EndDatetime
    FROM #Coalesced c
    JOIN dbo.visit_providers_in_buckets vpb ON vpb.prov_key_MQ = c.Staff_Staff_ID;

END
GO


