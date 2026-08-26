USE [ourStagingDatabase]
GO

/* first stab, WARNING: This ignores the frequency (not even in base)
and ignores priority, two critical items that need to be considered.
Otherwise, there are some gems here.
  
Note, ourStagingDatabase, dbserver does not exist.  You know what you know */

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE VIEW [dbo].[vw_TemplateBlocksNormalized] AS

WITH Base AS (
    SELECT
        st.Staff_Staff_ID,
        Activity      = st.TemplateDesc,
        TemplateType  = st.TemplateType,
        StartDate     = CAST(st.TemplStartDate - 36163 AS DATETIME),
        StartTimeRaw  = CONVERT(TIME, DATEADD(MILLISECOND, (st.TemplStartTime - 1) * 10, 0)),
        EndDateRaw    = CAST(st.TemplEndDate - 36163 AS DATETIME),
        EndTimeRaw    = CONVERT(TIME, DATEADD(MILLISECOND, (st.TemplEndTime - 1) * 10, 0))
    FROM [dbserver].[Mosaiq].[dbo].[SchTempl] st WITH (NOLOCK)
    WHERE st.disabled = 0
      AND st.TemplateType IN (1, 2, 3, 4, 6)   -- Holidays, Vacation, Prof Vacation, Clinic Hours, Custom
),

DatesFixed AS (
    SELECT
        *,
        -- No-end-date sentinel (1800-12-28) confirmed by sampling: means "same day as start"
        EndDate = CASE
                     WHEN CONVERT(VARCHAR(10), EndDateRaw, 121) = '1800-12-28'
                     THEN StartDate
                     ELSE EndDateRaw
                  END,
        -- Full-day sentinel confirmed: 23:59:59.99 start AND end time = whole-day block, not a literal 1-second window
        IsFullDaySentinel = CASE
                     WHEN StartTimeRaw = '23:59:59.9900000' AND EndTimeRaw = '23:59:59.9900000'
                     THEN 1 ELSE 0
                  END
    FROM Base
),

TimesFixed AS (
    SELECT
        *,
        StartTime = CASE WHEN IsFullDaySentinel = 1 THEN CAST('00:00:00' AS TIME) ELSE StartTimeRaw END,
        EndTime   = CASE WHEN IsFullDaySentinel = 1 THEN CAST('23:59:59' AS TIME) ELSE EndTimeRaw   END
    FROM DatesFixed
),

Normalized AS (
    SELECT
        *,
        NormActivity = ' ' + REPLACE(REPLACE(UPPER(Activity), '/', ' '), '_', ' ') + ' '
    FROM TimesFixed
),

Classified AS (
    SELECT
        Staff_staff_ID,
        Activity,
        TemplateType,
        StartDatetime = DATEADD(SECOND, DATEDIFF(SECOND, 0, StartTime), StartDate),
        EndDatetime   = DATEADD(SECOND, DATEDIFF(SECOND, 0, EndTime),   EndDate),
        Block_Type = CASE
            -- Types 1/2/3: sampled and confirmed clean BLOCKING signal; no exceptions found
            WHEN TemplateType IN (1, 2, 3) THEN 'BLOCKING'

            -- Types 4 and 6: text-classify, since Type 4 already caught a mislabeled meeting (Trujillo)
            WHEN NormActivity LIKE '% NOT IN CLINIC %'   THEN 'BLOCKING'
            WHEN NormActivity LIKE '% OUT OF CLINIC %'   THEN 'BLOCKING'
            WHEN NormActivity LIKE '% PTO %'             THEN 'BLOCKING'
            WHEN NormActivity LIKE '% DO NOT BOOK %'     THEN 'BLOCKING'
            WHEN NormActivity LIKE '% CLOSED %'          THEN 'BLOCKING'
            WHEN NormActivity LIKE '% VACATION %'        THEN 'BLOCKING'
            WHEN NormActivity LIKE '% BLOCK %'           THEN 'BLOCKING'
            WHEN NormActivity LIKE '% MEETING %'         THEN 'BLOCKING'
            WHEN NormActivity LIKE '% ANNUAL LEAVE %'    THEN 'BLOCKING'
            WHEN NormActivity LIKE '% INTERVIEW %'       THEN 'BLOCKING'
            WHEN NormActivity LIKE '% MOCK ORALS %'      THEN 'BLOCKING'
            WHEN NormActivity LIKE '%SURG%'              THEN 'BLOCKING'
            WHEN NormActivity LIKE '% NO APP %'          THEN 'BLOCKING'
            WHEN NormActivity LIKE '% OUT OF OFFICE %'   THEN 'BLOCKING'
            WHEN NormActivity LIKE '% OOO %'             THEN 'BLOCKING'
            WHEN NormActivity LIKE '% MATERNITY LEAVE %' THEN 'BLOCKING'
            WHEN NormActivity LIKE '%------%'       THEN 'BLOCKING'
            WHEN NormActivity LIKE '%SPECIAL CLINIC%' THEN 'BLOCKING'  -- not entirely sure, could be mixed?
            WHEN NormActivity LIKE '%SPEICAL CLINIC%' THEN 'BLOCKING'
     			  WHEN NormActivity LIKE '%BREAK ' THEN 'BLOCKING'
		     	  WHEN NormActivity LIKE '%LUNCH ' THEN 'BLOCKING'
            WHEN TemplateType = 4 THEN 'FREE_SLOT'   -- Clinic Hours default, if not caught above
            WHEN TemplateType = 6 THEN 'FREE_SLOT'   -- Custom default, if not caught above -- will come back to bite us
            ELSE 'UNKNOWN'
        END
    FROM Normalized
)

SELECT DISTINCT
    Provider      = vpb.prov_name_MQ,
    c.Activity,
    c.TemplateType,
    c.Block_Type,
    c.StartDatetime,
    c.EndDatetime
FROM Classified c
JOIN [ourStagingDatabase].[dbo].[visit_providers_in_buckets] vpb ON c.Staff_Staff_ID = vpb.prov_key_MQ
WHERE vpb.prov_title_bucket = 'Physician/APP'
  AND vpb.is_scheduling_prov = 'Y'
  AND vpb.prov_status_MQ = 'Active'
  AND c.EndDatetime >= GETDATE()
GO


