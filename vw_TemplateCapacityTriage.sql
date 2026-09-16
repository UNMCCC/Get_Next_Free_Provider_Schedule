USE [MosaiqAdmin]
GO

/****** Object:  View [dbo].[vw_TemplateCapacityTriage]    Script Date: 9/16/2026 9:00:17 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


-- NOTE: the 13 explicit-max rows seeded in the previous version 
-- of this script are no longer needed here 
-- ufn_ExtractMaxPatients (below) resolves all of them automatically 
-- (verified: 12, 9, 5, etc. all match what was previously hand-entered). 
-- This table is now reserved for
-- genuinely ambiguous cases only, e.g. dual-duration descriptions like:
--   INSERT INTO dbo.TemplateCapacityOverride (TemplateDescription, ManualDurationMinutes, Source, Notes)
--   VALUES ('NP/CCIR 60 min OV/PC 30min', 30, 'Katybeth review pending', 'Confirm: OV/PC portion (30min) or NP/CCIR portion (60min)?');
-- Leave empty until Katybeth's team has actually made those calls --
-- don't seed guesses here.

------------------------------------------------------------------------
-- 3) TRIAGE VIEW -- run this against real distinct FREE_SLOT
--    descriptions (once blocking classification is finalized) to see
--    exactly what tier each row lands in BEFORE wiring anything into
--    Stage 3. Nothing here writes to the datamart yet.
------------------------------------------------------------------------
ALTER   VIEW [dbo].[vw_TemplateCapacityTriage] AS
SELECT
    st.TemplateDesc AS TemplateDescription,
    st.TemplRule,
    st.RuleLimit,
    ovr.ManualCapacity,
    ovr.ManualDurationMinutes,
    dbo.ufn_ExtractDurationMinutes(st.TemplateDesc) AS ParsedDurationMinutes,
    dbo.ufn_ExtractMaxPatients(st.TemplateDesc)     AS ParsedMaxPatients,
    CASE
        WHEN st.RuleLimit >= 1 THEN 'USE_RULELIMIT'
        WHEN ovr.ManualCapacity IS NOT NULL OR ovr.ManualDurationMinutes IS NOT NULL THEN 'USE_MANUAL_OVERRIDE'
        WHEN dbo.ufn_ExtractDurationMinutes(st.TemplateDesc) IS NOT NULL THEN 'USE_DURATION_DERIVED'
        WHEN dbo.ufn_ExtractMaxPatients(st.TemplateDesc) IS NOT NULL THEN 'USE_MAX_PARSED'
        WHEN st.TemplateDesc LIKE '%max%'
            THEN 'NEEDS_CONFIGURED_LIMIT'   -- says "max" but no non-date number anywhere in the text --
                                              -- this is a real upstream data gap (nobody ever set the
                                              -- actual limit), not a parsing failure. Report these back
                                              -- to Katybeth's team as templates needing a real RuleLimit,
                                              -- rather than trying to derive a number from nothing.
        WHEN st.TemplateDesc LIKE '%[0-9]%'
             AND (st.TemplateDesc LIKE '%limit%' OR st.TemplateDesc LIKE '%min%')
            THEN 'NEEDS_REVIEW'   -- e.g. dual-duration descriptions like "60 min OV/PC 30min" --
                                    -- genuinely ambiguous, needs a human decision recorded in
                                    -- dbo.TemplateCapacityOverride, not an automatic guess.
        ELSE 'STAYS_UNLIMITED'
    END AS DerivationTier
FROM [hsc-cc-mqdb28].mosaiq.dbo.SchTempl st WITH (NOLOCK)                                     -- TODO: confirm this is the right source table/column for guideline text
LEFT JOIN dbo.TemplateCapacityOverride ovr
    ON ovr.TemplateDescription = st.TemplateDesc;
GO


