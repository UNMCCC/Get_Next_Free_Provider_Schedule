USE [MosaiqAdmin]
GO

/* =====================================================================
   dbo.NextFreeSlotsDatamart
   =====================================================================
   Persisted, all-providers version of what sp_GetNextFreeSlots
   computes on demand for one provider. Rebuilt on a schedule (see
   sp_RefreshFreeSlotsDatamart at the bottom) so a scheduler-facing
   report/app can just SELECT from a table instead of calling a proc
   per provider.

   Stores ALL eligible upcoming windows within the horizon (not just
   the top 3) with a SlotRank per provider, so any consumer can either
   read the whole thing or filter to WHERE SlotRank <= 3 themselves.

   OPEN ITEM -- Department/Location (Santa Fe case):
   Per your Santa Fe finding: some templates are location-restricted
   (only valid for patients of that satellite clinic) even though
   they show up as ordinary FREE_SLOT time with real OpenCapacity.
   The Guideline Form has a "Department" field (seen in every
   screenshot -- "UNM CRTC Medical Oncology", "Global", etc.) that is
   almost certainly where this lives in SchTempl, but I don't have the
   confirmed real column name, so it is NOT wired in yet. Once you
   confirm the column name (with Katybeth or by inspecting SchTempl
   directly), add it in THREE places, all marked "-- TODO: Department"
   below and in the two scripts from earlier in this conversation:
     1) sp_BuildTemplateOccurrences, #TemplBase SELECT list
     2) sp_BuildTemplateOccurrences, final INSERT into
        dbo.TemplateOccurrencesExpanded (add a Department column there too)
     3) sp_BuildProviderEffectiveSchedule, carried through #Coalesced
        and the final INSERT into dbo.ProviderEffectiveSchedule
   Then it will flow through automatically to this datamart. Until
   then, treat any FREE_SLOT window whose Activity text mentions a
   satellite location (e.g. "Santa Fe") as a manual red flag for
   schedulers -- don't book general patients into it.

   OPEN ITEM -- PossiblyDeparted (data governance, not a code bug):
   The provider status fields on the parent staff table (and the
   curated visit_providers_in_buckets derived from it) have been
   confirmed unreliable for detecting departures -- a provider who
   left roughly a year ago (last real patient visit Dec 2024) is
   still marked Active/schedulable at the root. No status field
   anywhere in Mosaiq can be trusted to answer "has this person
   actually left." The only reliable signal available is real patient
   activity, so PossiblyDeparted is computed from days since the
   provider's last recorded visit (dbo.visits_in_buckets), NOT from
   any status flag.
   This is deliberately a SOFT, VISIBLE FLAG, not a filter -- it never
   removes anyone from the datamart. Providers do take real extended
   leave (parental, medical, sabbatical) and do come back ("boomerangs"),
   so silently excluding on inactivity risks hiding a legitimately
   returning provider, the same class of harm as showing a departed
   one as available. Let a human (scheduler, Katybeth, etc.) decide
   what to do with a flagged row.
   This is a data governance gap, not something fixable from this
   pipeline -- worth escalating separately to whoever owns the
   staff/provider status sync process, since any other system trusting
   that same status field has the same blind spot.
   ===================================================================== */

IF OBJECT_ID('dbo.NextFreeSlotsDatamart', 'U') IS NOT NULL
    DROP TABLE dbo.NextFreeSlotsDatamart;
GO

CREATE TABLE dbo.NextFreeSlotsDatamart
(
    Staff_Staff_ID    INT           NOT NULL,
    Provider          NVARCHAR(200) NULL,
    TemplatePK        INT           NOT NULL,
    Activity          NVARCHAR(200) NULL,   -- template name/description -- tells the scheduler what can be booked here
    -- Department     NVARCHAR(200) NULL,  -- TODO: Department -- uncomment once column name is confirmed upstream
    TemplRule         INT           NULL,
    RuleName          VARCHAR(50)   NULL,   -- human-readable, from the TemplRule table in the README
    RuleLimit         INT           NULL,
    BookedCount       INT           NULL,
    OpenCapacity      INT           NULL,   -- RuleLimit - BookedCount; NULL = uncapped
    StartDatetime     DATETIME2(0)  NOT NULL,
    EndDatetime       DATETIME2(0)  NOT NULL,
    SlotRank          INT           NOT NULL,   -- 1 = this provider's soonest eligible window
    LastVisitDate     DATE          NULL,       -- most recent real patient visit for this provider (visits_in_buckets)
    DaysSinceLastVisit INT          NULL,       -- NULL if provider has no recorded visits at all
    PossiblyDeparted  BIT           NULL,       -- SOFT FLAG ONLY -- see header note; never auto-excludes anyone
    BuiltAt           DATETIME2(0)  NOT NULL
);
GO

CREATE INDEX IX_NextFreeSlotsDatamart_Provider_Rank
    ON dbo.NextFreeSlotsDatamart (Staff_Staff_ID, SlotRank);
GO
