USE MosaiqAdmin
GO
/****** Object:  View [dbo].[vw_ScheduleNormalized]    Script Date: 8/25/2026 8:05:00 PM ******/
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
   staff_id           -- FK to Staff
   Activity  NVARCHAR(200)   -- appointment type or block/note label
   App_DtTm  DATETIME2(0)    -- appointment start
   Duration_time INT         -- duration in SECONDS

dbo.Staff (proxy: visit_provider_in_buckets)
   staff_id
   last_name
   first_name
===================================================================== */

------------------------------------------------------------------------
-- 0) NORMALIZING VIEWS — adjust here if column types differ
------------------------------------------------------------------------
CREATE VIEW [dbo].[vw_ScheduleNormalized] AS
SELECT DISTINCT
       Staff_Staff_ID = vpb.prov_key_MQ,    -- ADDED: expose the ID directly so
                                             -- downstream consumers (e.g. #Busy
                                             -- in sp_NextFreeSlotsDatamart) can
                                             -- join on ID instead of re-matching
                                             -- back to an ID by provider name.
       Provider        = vpb.prov_name_MQ,
       sch.Activity,
       StartDatetime = sch.App_DtTm,
       EndDatetime   = DATEADD(MILLISECOND, 10*sch.Duration_time, sch.App_DtTm)
FROM   [dbserver].Mosaiq.dbo.Schedule sch WITH (NOLOCK)
JOIN   [MosaiqAdmin].[dbo].[visit_providers_in_buckets] vpb ON sch.Staff_ID = vpb.prov_key_MQ
WHERE  vpb.prov_title_bucket = 'Physician/APP'   -- only docs
  AND  vpb.is_scheduling_prov = 'Y'              -- can be scheduled
  AND  vpb.prov_status_MQ = 'Active'             -- are active
  AND  sch.App_DtTm > GETDATE()                  -- future schedule
  AND  sch.SchStatus_Hist_SD <> 'O'
  AND  sch.SchStatus_Hist_SD <> 'S'   -- not cancelled, bumped
  AND  sch.SchStatus_Hist_SD <> 'F'   -- not cancelled, bumped
  AND  sch.SchStatus_Hist_SD <> 'X'   -- not cancelled, bumped
  AND  sch.Version = 0                -- tip of record (last vers)
GO

/* ----------------------------------------------------------------------
   NOTE (not changed in this pass, flagged for awareness):
   This view still duplicates the same 3-part filter that lives in
   dbo.vw_ActiveSchedulingProviders, and does NOT exclude the "Infusion"
   scheduling placeholder. In practice this doesn't currently produce
   wrong output, because sp_NextFreeSlotsDatamart's #FreeIntervals step
   is now gated through vw_ActiveSchedulingProviders (which does exclude
   Infusion and applies the same 3-part filter) -- so any stray Infusion
   rows here simply have no matching FreeInterval to attach to and are
   silently ignored downstream. Consider refactoring this view to join
   vw_ActiveSchedulingProviders directly as a future cleanup, so there is
   a single source of truth instead of two copies of the same filter.
   ---------------------------------------------------------------------- */