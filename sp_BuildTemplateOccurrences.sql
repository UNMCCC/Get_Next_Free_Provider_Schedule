USE [ourStagingDB]
GO

/****** Object:  StoredProcedure [dbo].[sp_BuildTemplateOccurrences]    Script Date: 8/26/2026 2:10:13 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [dbo].[sp_BuildTemplateOccurrences]
    @HorizonDays INT = 120
AS
BEGIN
    SET NOCOUNT ON;
    -- Sunday = 1 ... Saturday = 7, to match the README's weekday
    -- numbering (used directly by Freq_Type 32/128) and its bitmask
    -- convention (Sun=2^0 ... Sat=2^6, used by Freq_Type 8).
    SET DATEFIRST 7;

    DECLARE @WindowStart DATE = CAST(GETDATE() AS DATE);
    DECLARE @WindowEnd   DATE = DATEADD(DAY, @HorizonDays, @WindowStart);

    --------------------------------------------------------------------
    -- 0) Tally table for date-offset expansion (daily / weekly)
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Numbers') IS NOT NULL DROP TABLE #Numbers;
    SELECT TOP (2000)
        n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
    INTO #Numbers
    FROM sys.all_objects a
    CROSS JOIN sys.all_objects b;

    --------------------------------------------------------------------
    -- 1) Base template rows -- same date/time decode as the original
    --    "first stab" view, plus the frequency + priority columns it
    --    was missing.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#TemplBase') IS NOT NULL DROP TABLE #TemplBase;
    SELECT
        st.SCT_ID,
        st.Staff_Staff_ID,
        Activity         = st.TemplateDesc,
        TemplateType     = st.TemplateType,
        Priority         = st.Priority,
        TemplRule        = st.TemplRule,
        RuleLimit        = st.RuleLimit,
        Freq_Type        = st.Freq_Type,
        Freq_Interval    = st.Freq_Interval,
        Freq_RelInterval = st.Freq_Relative_Interval,
        Freq_RecurFactor = st.Freq_Recurrence_Factor,
        StartDate        = CAST(st.TemplStartDate - 36163 AS DATETIME),
        StartTimeRaw     = CONVERT(TIME, DATEADD(MILLISECOND, (st.TemplStartTime - 1) * 10, 0)),
        EndDateRaw       = CAST(st.TemplEndDate - 36163 AS DATETIME),
        EndTimeRaw       = CONVERT(TIME, DATEADD(MILLISECOND, (st.TemplEndTime - 1) * 10, 0))
    INTO #TemplBase
    FROM [serverName].[Mosaiq].[dbo].[SchTempl] st WITH (NOLOCK)
    WHERE st.Disabled = 0
      AND st.TemplateType IN (1, 2, 3, 4, 6) -- Holidays, Vacation, Prof Vacation, Clinic Hours, Custom
      AND CAST(st.TemplStartDate - 36163 AS DATETIME) <= @WindowEnd; -- skip templates that don't even start until after our horizon

    --------------------------------------------------------------------
    -- 2) Resolve sentinels: open-end flag, full-day flag, and the
    --    effective end date used to bound recurrence expansion.
    --    See assumption (1) at the top of this script.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#TemplResolved') IS NOT NULL DROP TABLE #TemplResolved;
    SELECT
        *,
        IsOpenEnded       = CASE WHEN EndDateRaw = '1800-12-28' THEN 1 ELSE 0 END,
        IsFullDaySentinel = CASE WHEN StartTimeRaw = '23:59:59.9900000'
                                   AND EndTimeRaw   = '23:59:59.9900000' THEN 1 ELSE 0 END
    INTO #TemplResolved
    FROM #TemplBase;

    IF OBJECT_ID('tempdb..#TemplFinal') IS NOT NULL DROP TABLE #TemplFinal;
    SELECT
        *,
        EffectiveEndDate = CASE
            WHEN IsOpenEnded = 0             THEN EndDateRaw   -- explicit end date: honor it
            WHEN ISNULL(Freq_Type, 0) = 0    THEN StartDate    -- one-time + open-end sentinel: same day as start (unchanged from original view)
            ELSE @WindowEnd                                    -- recurring + open-end sentinel: ride out the horizon
        END,
        StartTime = CASE WHEN IsFullDaySentinel = 1 THEN CAST('00:00:00' AS TIME) ELSE StartTimeRaw END,
        EndTime   = CASE WHEN IsFullDaySentinel = 1 THEN CAST('23:59:59' AS TIME) ELSE EndTimeRaw   END
    INTO #TemplFinal
    FROM #TemplResolved;

    --------------------------------------------------------------------
    -- 3) Expand occurrences, one branch per frequency type. Freq_Type
    --    is tested with bitwise AND (not strict equality) since the
    --    README notes it can appear as an OR'd combo of bits.
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#OccAll') IS NOT NULL DROP TABLE #OccAll;
    CREATE TABLE #OccAll (PK INT NOT NULL, OccurrenceDate DATE NOT NULL);

    -- 3a) One-time templates (Freq_Type NULL/0): single occurrence
    INSERT INTO #OccAll (PK, OccurrenceDate)
    SELECT SCT_ID, StartDate
    FROM #TemplFinal
    WHERE ISNULL(Freq_Type, 0) = 0
      AND StartDate BETWEEN @WindowStart AND @WindowEnd;

    -- 3b) Freq_Type & 4 = 4 -> every X days (Freq_Interval = X)
    INSERT INTO #OccAll (PK, OccurrenceDate)
    SELECT t.SCT_ID, x.d
    FROM #TemplFinal t
    CROSS APPLY (
        SELECT d = DATEADD(DAY, n.n * NULLIF(t.Freq_Interval, 0), t.StartDate)
        FROM #Numbers n
    ) x
    WHERE (t.Freq_Type & 4) = 4
      AND x.d BETWEEN t.StartDate AND t.EffectiveEndDate
      AND x.d BETWEEN @WindowStart AND @WindowEnd;

    -- 3c) Freq_Type & 8 = 8 -> every X weeks, on the weekdays set in
    --     the Freq_Interval bitmask (Sun=1, Mon=2, Tue=4, Wed=8,
    --     Thu=16, Fri=32, Sat=64). See assumption (2) re: the "every
    --     X weeks" factor and its 0/NULL default.
    INSERT INTO #OccAll (PK, OccurrenceDate)
    SELECT t.SCT_ID, x.d
    FROM #TemplFinal t
    CROSS APPLY (
        SELECT d = DATEADD(DAY, n.n, t.StartDate)
        FROM #Numbers n
    ) x
    WHERE (t.Freq_Type & 8) = 8
      AND x.d BETWEEN t.StartDate AND t.EffectiveEndDate
      AND x.d BETWEEN @WindowStart AND @WindowEnd
      AND (t.Freq_Interval & POWER(2, DATEPART(WEEKDAY, x.d) - 1)) > 0
      AND DATEDIFF(WEEK, t.StartDate, x.d) % ISNULL(NULLIF(t.Freq_RecurFactor, 0), 1) = 0;

    -- 3d) Freq_Type & 16 = 16 -> day X of every Y months
    --     (Freq_Interval = X day-of-month, Freq_RecurFactor = Y months)
    INSERT INTO #OccAll (PK, OccurrenceDate)
    SELECT t.SCT_ID, x.d
    FROM #TemplFinal t
    CROSS APPLY (
        SELECT MonthStart = DATEADD(MONTH, n.n * ISNULL(NULLIF(t.Freq_RecurFactor, 0), 1),
                                     DATEFROMPARTS(YEAR(t.StartDate), MONTH(t.StartDate), 1))
        FROM #Numbers n
        WHERE n.n <= 60 -- cap iterations; raise if @HorizonDays grows well beyond ~120 days
    ) m
    CROSS APPLY (
        SELECT d = DATEFROMPARTS(YEAR(m.MonthStart), MONTH(m.MonthStart), t.Freq_Interval)
        WHERE t.Freq_Interval <= DAY(EOMONTH(m.MonthStart)) -- skip months without that day (e.g. day 31 in April)
    ) x
    WHERE (t.Freq_Type & 16) = 16
      AND x.d BETWEEN t.StartDate AND t.EffectiveEndDate
      AND x.d BETWEEN @WindowStart AND @WindowEnd;

    -- 3e) Freq_Type & 32 = 32 -> Nth <DayOfWeek> of every Z months
    --     (Freq_Interval = DayOfWeek 1-7, Freq_RelInterval = Nth
    --     1-4 / 5=Last, Freq_RecurFactor = Z months)
    INSERT INTO #OccAll (PK, OccurrenceDate)
    SELECT t.SCT_ID, d.OccDate
    FROM #TemplFinal t
    CROSS APPLY (
        SELECT MonthStart = DATEADD(MONTH, n.n * ISNULL(NULLIF(t.Freq_RecurFactor, 0), 1),
                                     DATEFROMPARTS(YEAR(t.StartDate), MONTH(t.StartDate), 1))
        FROM #Numbers n
        WHERE n.n <= 60
    ) m
    CROSS APPLY (
        SELECT wd.OccDate,
               rn      = ROW_NUMBER() OVER (ORDER BY wd.OccDate),
               rn_desc = ROW_NUMBER() OVER (ORDER BY wd.OccDate DESC)
        FROM (
            SELECT OccDate = DATEADD(DAY, nn.n, m.MonthStart)
            FROM #Numbers nn
            WHERE nn.n < 31
              AND MONTH(DATEADD(DAY, nn.n, m.MonthStart)) = MONTH(m.MonthStart)
              AND DATEPART(WEEKDAY, DATEADD(DAY, nn.n, m.MonthStart)) = t.Freq_Interval
        ) wd
    ) d
    WHERE (t.Freq_Type & 32) = 32
      AND ((t.Freq_RelInterval < 5 AND d.rn = t.Freq_RelInterval)
           OR (t.Freq_RelInterval = 5 AND d.rn_desc = 1))
      AND d.OccDate BETWEEN t.StartDate AND t.EffectiveEndDate
      AND d.OccDate BETWEEN @WindowStart AND @WindowEnd;

    -- 3f) Freq_Type & 64 = 64 -> day X of month Y, every year
    --     (Freq_Interval = X day, Freq_RecurFactor = Y month)
    INSERT INTO #OccAll (PK, OccurrenceDate)
    SELECT t.SCT_ID, x.d
    FROM #TemplFinal t
    CROSS APPLY (
        SELECT YearN = YEAR(t.StartDate) + n.n
        FROM #Numbers n
        WHERE n.n <= 5 -- a handful of years comfortably covers a 120-ish day horizon; raise if @HorizonDays grows a lot
    ) y
    CROSS APPLY (
        SELECT d = DATEFROMPARTS(y.YearN, t.Freq_RecurFactor, t.Freq_Interval)
        WHERE t.Freq_Interval <= DAY(EOMONTH(DATEFROMPARTS(y.YearN, t.Freq_RecurFactor, 1)))
    ) x
    WHERE (t.Freq_Type & 64) = 64
      AND x.d BETWEEN t.StartDate AND t.EffectiveEndDate
      AND x.d BETWEEN @WindowStart AND @WindowEnd;

    -- 3g) Freq_Type & 128 = 128 -> Nth <DayOfWeek> of month Y, every year
    INSERT INTO #OccAll (PK, OccurrenceDate)
    SELECT t.SCT_ID, d.OccDate
    FROM #TemplFinal t
    CROSS APPLY (
        SELECT YearN = YEAR(t.StartDate) + n.n
        FROM #Numbers n
        WHERE n.n <= 5
    ) y
    CROSS APPLY (
        SELECT MonthStart = DATEFROMPARTS(y.YearN, t.Freq_RecurFactor, 1)
    ) m
    CROSS APPLY (
        SELECT wd.OccDate,
               rn      = ROW_NUMBER() OVER (ORDER BY wd.OccDate),
               rn_desc = ROW_NUMBER() OVER (ORDER BY wd.OccDate DESC)
        FROM (
            SELECT OccDate = DATEADD(DAY, nn.n, m.MonthStart)
            FROM #Numbers nn
            WHERE nn.n < 31
              AND MONTH(DATEADD(DAY, nn.n, m.MonthStart)) = MONTH(m.MonthStart)
              AND DATEPART(WEEKDAY, DATEADD(DAY, nn.n, m.MonthStart)) = t.Freq_Interval
        ) wd
    ) d
    WHERE (t.Freq_Type & 128) = 128
      AND ((t.Freq_RelInterval < 5 AND d.rn = t.Freq_RelInterval)
           OR (t.Freq_RelInterval = 5 AND d.rn_desc = 1))
      AND d.OccDate BETWEEN t.StartDate AND t.EffectiveEndDate
      AND d.OccDate BETWEEN @WindowStart AND @WindowEnd;

    --------------------------------------------------------------------
    -- 4) Attach time-of-day, build full datetimes
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#OccDatetime') IS NOT NULL DROP TABLE #OccDatetime;
    SELECT DISTINCT
        o.PK,
        t.Staff_Staff_ID,
        t.Activity,
        t.TemplateType,
        t.Priority,
        t.TemplRule,
        t.RuleLimit,
        StartDatetime = DATEADD(SECOND, DATEDIFF(SECOND, 0, t.StartTime), CAST(o.OccurrenceDate AS DATETIME2(0))),
        EndDatetime   = DATEADD(SECOND, DATEDIFF(SECOND, 0, t.EndTime),   CAST(o.OccurrenceDate AS DATETIME2(0)))
    INTO #OccDatetime
    FROM #OccAll o
    JOIN #TemplFinal t ON t.SCT_ID = o.PK;

    --------------------------------------------------------------------
    -- 5) Classify Block_Type -- unchanged pattern-matching logic from
    --    the original vw_TemplateBlocksNormalized "first stab".
    --------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#OccClassified') IS NOT NULL DROP TABLE #OccClassified;
    SELECT
        *,
        NormActivity = ' ' + REPLACE(REPLACE(UPPER(Activity), '/', ' '), '_', ' ') + ' '
    INTO #OccClassified
    FROM #OccDatetime;

    IF OBJECT_ID('tempdb..#OccFinal') IS NOT NULL DROP TABLE #OccFinal;
    SELECT
        PK, Staff_Staff_ID, Activity, TemplateType, Priority, TemplRule, RuleLimit,
        StartDatetime, EndDatetime,
        Block_Type = CASE
           WHEN TemplateType IN (1, 2, 3)                THEN 'BLOCKING'
            WHEN NormActivity LIKE '% NOT IN CLINIC %'     THEN 'BLOCKING'
            WHEN NormActivity LIKE '% NON CLINIC %'        THEN 'BLOCKING'
            WHEN NormActivity LIKE '% OUT OF CLINIC %'     THEN 'BLOCKING'
            WHEN NormActivity LIKE '% PTO %'               THEN 'BLOCKING'
            WHEN NormActivity LIKE '% DO NOT BOOK %'       THEN 'BLOCKING'
            WHEN NormActivity LIKE '% DNB %'               THEN 'BLOCKING'
            WHEN NormActivity LIKE '% CLOSED %'            THEN 'BLOCKING'
            WHEN NormActivity LIKE '% VACATION %'          THEN 'BLOCKING'
            WHEN NormActivity LIKE '% BLOCK %'             THEN 'BLOCKING'
            WHEN NormActivity LIKE '% MEETING %'           THEN 'BLOCKING'
            WHEN NormActivity LIKE '% ANNUAL LEAVE %'      THEN 'BLOCKING'
            WHEN NormActivity LIKE '% INTERVIEW %'         THEN 'BLOCKING'
            WHEN NormActivity LIKE '% MOCK ORALS %'        THEN 'BLOCKING'
            WHEN NormActivity LIKE '%SURG%'                THEN 'BLOCKING'
            WHEN NormActivity LIKE '% NO APP %'            THEN 'BLOCKING'
            WHEN NormActivity LIKE '% OUT OF OFFICE %'     THEN 'BLOCKING'
            WHEN NormActivity LIKE '% OOO %'               THEN 'BLOCKING'
            WHEN NormActivity LIKE '% MATERNITY LEAVE %'   THEN 'BLOCKING'
            WHEN NormActivity LIKE '%------%'              THEN 'BLOCKING'
            WHEN NormActivity LIKE '%SPECIAL CLINIC%'      THEN 'BLOCKING' -- not entirely sure, could be mixed?
            WHEN NormActivity LIKE '%SPEICAL CLINIC%'      THEN 'BLOCKING'
            WHEN NormActivity LIKE '%BREAK '               THEN 'BLOCKING'
            WHEN NormActivity LIKE '%LUNCH '               THEN 'BLOCKING'
			WHEN NormActivity LIKE '%Clinic to start at 830a%' THEN 'BLOCKING' -- Andre
			WHEN NormActivity LIKE '%NO FNA CLINIC%'         THEN 'BLOCKING' -- Agarwal, Broehm
			WHEN NormActivity LIKE '%UNM Not in Clinic-%' THEN 'BLOCKING' -- andre, booth
			WHEN NormActivity LIKE '%Departed%' THEN 'BLOCKING' -- hadley
			WHEN NormActivity LIKE '%Depature%' THEN 'BLOCKING' -- jude khatib
			WHEN NormActivity LIKE '%Hashemi Out%' THEN 'BLOCKING' -- hashemi
			WHEN NormActivity LIKE '%Fellowship ending%' THEN 'BLOCKING' -- jones
			WHEN NormActivity LIKE '%LAST DAY Dr. MAZ%' THEN 'BLOCKING' -- hashemi
			WHEN NormActivity LIKE '%None clinic hours%' THEN 'BLOCKING' -- hashemi
			WHEN NormActivity LIKE '%Rounding%' THEN 'BLOCKING' -- hashemi
            WHEN TemplateType = 4                          THEN 'FREE_SLOT' -- Clinic Hours default, if not caught above
            WHEN TemplateType = 6                          THEN 'FREE_SLOT' -- Custom default, if not caught above
            ELSE 'UNKNOWN'

        END
    INTO #OccFinal
    FROM #OccClassified;

    --------------------------------------------------------------------
    -- 6) Persist. Priority/TemplRule/RuleLimit are carried through
    --    but NOT resolved here -- overlap/priority collapsing is the
    --    next stage, built on top of this table.
    --------------------------------------------------------------------
    TRUNCATE TABLE dbo.TemplateOccurrencesExpanded;

    INSERT INTO dbo.TemplateOccurrencesExpanded
        (TemplatePK, Staff_Staff_ID, Activity, TemplateType, Block_Type, Priority, TemplRule, RuleLimit, StartDatetime, EndDatetime)
    SELECT
        PK, Staff_Staff_ID, Activity, TemplateType, Block_Type, Priority, TemplRule, RuleLimit, StartDatetime, EndDatetime
    FROM #OccFinal
    WHERE EndDatetime >= GETDATE();

END
GO


