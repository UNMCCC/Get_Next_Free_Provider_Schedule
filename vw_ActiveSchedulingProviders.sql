/* ============================================================================
   dbo.vw_ActiveSchedulingProviders
   ----------------------------------------------------------------------------
   PURPOSE
   Restores the original 3-part "active scheduling provider" filter that was
   lost when Stage 2 (sp_BuildProviderEffectiveSchedule) was rewritten, and
   adds a non-excluding staleness signal (PossiblyDeparted / LastVisitDate /
   DaysSinceLastVisit) based on real visit history rather than the staff
   status field, which is known-unreliable (see Dr. Fine, Staff_Staff_ID
   2252 — Active/schedulable a year after her real last visit).

   DESIGN DECISIONS (confirmed)
   - PossiblyDeparted is a SOFT flag. It must never be used to hard-filter
     rows out of this view or downstream queries. Consumers decide what to
     do with it.
   - Staleness is computed from dbo.visits_in_buckets, joined by
     prov_key_MQ (numeric provider key), NOT by provider name. This sidesteps
     the name-matching fragility already flagged in #Busy / vw_ScheduleNormalized.
   - The 3-part filter (prov_title_bucket, is_scheduling_prov, prov_status_MQ)
     IS still a hard filter — this view answers "is this a schedulable
     provider row at all", which is a different question from "have they
     possibly departed". Do not conflate the two.

   REMAINING OPEN ITEM 
   1. 365-day PossiblyDeparted threshold is still an arbitrary default —
      decide deliberately rather than leaving as-is.
   2. "Infusion" provider exclusion below uses a PLACEHOLDER column name
      (prov_last_name) — visit_providers_in_buckets did not show a name
      column in the sample provided. Confirm the real column name and
      swap it in before deploying, or this filter will fail to compile.

   SCOPE DECISIONS (confirmed)
   - prov_title_bucket is restricted to exactly 'Physician/APP'. Everything
     else in that column (Administrative -> IT/HR/etc., machine resources
     like Versa3/Synergy/Tomo, PFSS -> patient/family support, counselors,
     navigators, Medical Support, Unknown, etc.) is out of scope for this
     pipeline. This is an ALLOWLIST, not a denylist — a new/unexpected
     bucket value added later will NOT silently sneak in, unlike a denylist
     which would let anything unrecognized through by default.
   - Even within 'Physician/APP', the row with last name "Infusion" is not
     a real clinician — it's a scheduling placeholder used to organize the
     infusion suite. Excluded explicitly by name since it otherwise passes
     every other filter (real Physician/APP bucket, Y, Active).

   DATA FORMAT NOTE (confirmed)
   appt_dt in visits_in_buckets is a DATE-typed column already, but its
   display/storage format is YYYYMMDD-style (e.g. 20241203), NOT a native
   SQL Server date literal in the usual sense — handled via TRY_CONVERT
   with style 112 below, which is the standard style code for YYYYMMDD.
   ============================================================================ */

CREATE OR ALTER VIEW dbo.vw_ActiveSchedulingProviders
AS
WITH LastVisit AS (
    /* One row per provider key: most recent real visit on file.
       Joined by prov_key_MQ deliberately — not by name — per Fine case query:
         SELECT MAX(appt_dt) FROM visits_in_buckets WHERE prov_key_MQ = 2252
       appt_dt is stored in YYYYMMDD format (e.g. 20241203) — decoded here
       with TRY_CONVERT style 112, the standard SQL Server style code for
       YYYYMMDD. TRY_CONVERT (not CONVERT) so a malformed/unexpected value
       returns NULL instead of blowing up the whole view. */
    SELECT
        vib.prov_key_MQ,
        MAX(TRY_CONVERT(date, CAST(vib.appt_dt AS varchar(8)), 112)) AS LastVisitDate
    FROM MosaiqAdmin.dbo.visits_in_buckets AS vib
    GROUP BY vib.prov_key_MQ
)
SELECT
    vp.prov_key_MQ                                AS Staff_Staff_ID,
    vp.prov_name_last_MQ,                            
    vp.prov_title_bucket,
    vp.is_scheduling_prov,
    vp.prov_status_MQ,
    lv.LastVisitDate,
    DATEDIFF(DAY, lv.LastVisitDate, GETDATE())    AS DaysSinceLastVisit,
    CASE
        WHEN lv.LastVisitDate IS NULL THEN 1                          -- never visited on record -> flag
        WHEN DATEDIFF(DAY, lv.LastVisitDate, GETDATE()) > 365 THEN 1  -- TODO: confirm 365-day threshold is the right cutoff
        ELSE 0
    END                                            AS PossiblyDeparted
FROM MosaiqAdmin.dbo.visit_providers_in_buckets AS vp
LEFT JOIN LastVisit AS lv
    ON lv.prov_key_MQ = vp.prov_key_MQ
WHERE
    vp.prov_title_bucket = 'Physician/APP'   -- allowlist: only clinical physicians/APPs are in scope
    AND vp.is_scheduling_prov = 'Y'
    AND vp.prov_status_MQ = 'Active'          -- kept as a hard filter per original 3-part logic; PossiblyDeparted
                                               -- above is the safety net for cases like Fine where this field lies
    AND vp.prov_name_last_MQ <> 'Infusion';     
                                               -- Excludes the infusion-suite scheduling placeholder, not a real doctor.
GO

/* ============================================================================
   SPOT-CHECK QUERIES (run after deploying, per your Next Steps #5)
   ============================================================================ */

-- Confirm the view compiles and returns rows at all
-- SELECT TOP 20 * FROM dbo.vw_ActiveSchedulingProviders;

-- Dr. Fine check: expect PossiblyDeparted = 1, LastVisitDate ~ Dec 2024
-- SELECT * FROM dbo.vw_ActiveSchedulingProviders WHERE Staff_Staff_ID = 2252;

-- Confirm the known inactive duplicate (2264) does NOT slip through as a
-- false-active row (per your note: "2264 corresponds to a sfine inactive
-- user (dupe) .. never used") -- note: since prov_status_MQ = 'Active' is a
-- hard filter, an Inactive dupe should simply not appear in this view at all
-- SELECT * FROM dbo.vw_ActiveSchedulingProviders WHERE Staff_Staff_ID = 2264;

-- Confirm the infusion-suite placeholder row does NOT appear in results
-- (update column name to match the real name column once confirmed)
-- SELECT * FROM dbo.vw_ActiveSchedulingProviders WHERE prov_last_name = 'Infusion';
