/* ============================================================================
   dbo.vw_ActiveSchedulingProviders
   ----------------------------------------------------------------------------
   PURPOSE
   Restores the original 3-part "active scheduling provider" filter that was
   lost when Stage 2 (sp_BuildProviderEffectiveSchedule) was rewritten.

   SCOPE (this is a roster/gate, not appointment or staleness data)
   Answers "is this row a real, in-scope, schedulable provider?" — nothing
   more. Real booked appointments live in vw_ScheduleNormalized. Staleness
   (PossiblyDeparted / LastVisitDate / DaysSinceLastVisit) is computed
   entirely inside sp_NextFreeSlotsDatamart (@StaleDaysThreshold, default
   180 days) rather than here, to avoid two independent, drifting copies
   of the same logic with two different thresholds. If a caller needs
   staleness alongside roster membership, join to
   dbo.NextFreeSlotsDatamart's staleness columns rather than duplicating
   the computation in this view.

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
   - prov_name_last_MQ confirmed as the real column name (words in that
     order — not prov_last_name_MQ).
   ============================================================================ */

CREATE OR ALTER VIEW dbo.vw_ActiveSchedulingProviders
AS
SELECT
    vp.prov_key_MQ        AS Staff_Staff_ID,
    vp.prov_name_last_MQ,
    vp.prov_title_bucket,
    vp.is_scheduling_prov,
    vp.prov_status_MQ
FROM MosaiqAdmin.dbo.visit_providers_in_buckets AS vp
WHERE
    vp.prov_title_bucket = 'Physician/APP'      -- allowlist: only clinical physicians/APPs are in scope
    AND vp.is_scheduling_prov = 'Y'
    AND vp.prov_status_MQ = 'Active'             -- hard filter per original 3-part logic
    AND vp.prov_name_last_MQ <> 'Infusion';      -- excludes the infusion-suite scheduling placeholder
GO

/* ============================================================================
   SPOT-CHECK QUERIES
   ============================================================================ */

-- Confirm the view compiles and returns rows at all
-- SELECT TOP 20 * FROM dbo.vw_ActiveSchedulingProviders;

-- Dr. Fine check: she SHOULD still appear here (roster membership is not
-- staleness-aware) -- PossiblyDeparted now only lives in
-- dbo.NextFreeSlotsDatamart, check her there instead:
-- SELECT * FROM dbo.NextFreeSlotsDatamart WHERE Staff_Staff_ID = 2252;

-- Confirm the known inactive duplicate (2264) does NOT slip through
-- SELECT * FROM dbo.vw_ActiveSchedulingProviders WHERE Staff_Staff_ID = 2264;

-- Confirm the infusion-suite placeholder row does NOT appear in results
-- SELECT * FROM dbo.vw_ActiveSchedulingProviders WHERE prov_name_last_MQ = 'Infusion';