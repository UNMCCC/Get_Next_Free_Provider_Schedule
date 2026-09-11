USE [MosaiqAdmin]
GO

/****** Object:  View [dbo].[vw_ScheduleNormalized]    Script Date: 9/10/2026 7:01:15 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO




/* This view takes real providers that are active, extracts their
   future appointments. Leans on provider_in_buckets and schedules.
   does not consider status'd appointments (cancels, bumps), does not
   consider versions of appointments (version=0).

   =====================================================================
   PART OF FIRST AVAILABLE SLOT — SQL Server (T-SQL)
   =====================================================================
   Given a provider's actual schedule (appointments + block/note rows)
   and their template working windows, finds the first real open gap
   of at least @MinGapMinutes, ignoring short breaks (e.g. lunch scraps).

   REAL BASE TABLES:

   dbo.Schedule
       staff_id        -- FK to Staff
       Activity        NVARCHAR(200)   -- appointment type or block/note label
       App_DtTm        DATETIME2(0)    -- appointment start
       Duration_time    INT             -- duration in SECONDS

   dbo.Staff (proxy: visit_provider_in_buckets)
       staff_id
       last_name
       first_name

   dbo.Sch_Template_Blocks_Custom
       Provider        NVARCHAR(200)   -- already "Last, First" format
       Activity        NVARCHAR(200)   -- template block name
       From_Date       DATE
       From_Time       TIME(0)
       To_Date         DATE
       To_Time         TIME(0)

   Two views below normalize these into the shape the merge/gap logic
   needs (Provider as "Last, First", a single StartDatetime/EndDatetime
   pair for bookings, and a single WindowStart/WindowEnd pair for
   template blocks). If a working day has no template row, the function
   falls back to inferring that day's window from the actual Schedule
   rows (min(start) to max(end)) — weaker, but keeps things working
   until every provider/day has a template block.
   ===================================================================== */

------------------------------------------------------------------------
-- 0) NORMALIZING VIEWS — adjust here if column types differ
------------------------------------------------------------------------
CREATE   VIEW [dbo].[vw_ScheduleNormalized] AS
SELECT DISTINCT
    Provider      = vpb.prov_name_MQ,
    sch.Activity,
    StartDatetime = sch.App_DtTm,
    EndDatetime   = DATEADD(MILLISECOND, 10*sch.Duration_time, sch.App_DtTm)
FROM [HSC-CC-MQDB28].Mosaiq.dbo.Schedule sch WITH (NOLOCK)
JOIN [MosaiqAdmin].[dbo].[visit_providers_in_buckets]  vpb on sch.Staff_ID= vpb.prov_key_MQ
  where vpb.prov_title_bucket='Physician/APP'  -- only docs
  and vpb.is_scheduling_prov='Y'               -- can be scheduled
  and vpb.prov_status_MQ='Active'              -- are active
  and sch.App_DtTm > GETDATE()                 -- future schedule
  and sch.SchStatus_Hist_SD <> 'O'
  and sch.SchStatus_Hist_SD <> 'S' -- not cancelled, bumped
  and sch.SchStatus_Hist_SD <> 'F' -- not cancelled, bumped
  and sch.SchStatus_Hist_SD <> 'X' -- not cancelled, bumped
  and sch.Version = 0                          -- tip of record (last vers)
GO

