
IF OBJECT_ID('dbo.TemplateCapacityOverride', 'U') IS NULL
BEGIN
------------------------------------------------------------------------
-- 2) Manual override table -- now only for genuinely ambiguous cases
--    fn_ExtractMaxPatients can't safely resolve: multiple non-date
--    numbers equally plausible, dual-duration descriptions (e.g.
--    "NP/CCIR 60 min OV/PC 30min"), or any row a human reviewer wants
--    to force to a specific value regardless of what parses.
------------------------------------------------------------------------
-- NOTE: the 13 explicit-max rows seeded in the previous version of this
-- script are no longer needed here -- fn_ExtractMaxPatients (below)
-- resolves all of them automatically (verified: 12, 9, 5, etc. all match
-- what was previously hand-entered). This table is now reserved for
-- genuinely ambiguous cases only, e.g. dual-duration descriptions like:
--   INSERT INTO dbo.TemplateCapacityOverride (TemplateDescription, ManualDurationMinutes, Source, Notes)
--   VALUES ('NP/CCIR 60 min OV/PC 30min', 30, 'Katybeth review pending', 'Confirm: OV/PC portion (30min) or NP/CCIR portion (60min)?');
-- Leave empty until Katybeth's team has actually made those calls --
-- don't seed guesses here.
    CREATE TABLE dbo.TemplateCapacityOverride (
        TemplateDescription     NVARCHAR(200) NOT NULL PRIMARY KEY,   -- TODO: consider keying by TemplatePK instead if descriptions aren't guaranteed unique per template
        ManualCapacity          INT NULL,        -- direct patient-count override
        ManualDurationMinutes   INT NULL,        -- OR: which duration to use when a description states more than one (e.g. "NP/CCIR 60 min OV/PC 30min")
        Source                  NVARCHAR(100) NULL,     -- e.g. 'Katybeth review 2026-09-15'
        Notes                   NVARCHAR(400) NULL,
        CreatedAt               DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
        CONSTRAINT CK_TemplateCapacityOverride_OneValueSet
            CHECK (ManualCapacity IS NOT NULL OR ManualDurationMinutes IS NOT NULL)
    );
END
GO



