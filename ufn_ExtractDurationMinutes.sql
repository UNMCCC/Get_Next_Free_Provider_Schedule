USE [MosaiqAdmin]
GO
/****** Object:  UserDefinedFunction [dbo].[ufn_ExtractDurationMinutes]    Script Date: 9/16/2026 7:16:47 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER   FUNCTION [dbo].[ufn_ExtractDurationMinutes] (@Description NVARCHAR(200))
RETURNS INT
AS
BEGIN

/* ============================================================================
   Duration-derived capacity for RuleLimit = 0 FREE_SLOT templates
   ----------------------------------------------------------------------------
   BACKGROUND
   Some guidelines have no configured RuleLimit but state an intended
   appointment duration or explicit patient cap in their free-text
   description (e.g. "Adams Pre-Chemo 20 mins", "MAX 8 NP/IR Patients ONLY").
   This adds a way to derive an effective capacity from that text, WITHOUT
   silently guessing wrong on ambiguous phrasing -- see the triage view at
   the bottom, which is meant to be reviewed by a human before this feeds
   Stage 3.

   PRECEDENCE (confirmed)

     1. RuleLimit >= 1                          -> use as-is (unchanged, most authoritative)
     2. RuleLimit = 0 AND manual override set    -> use override (hand-confirmed by Katybeth's team)
     3. RuleLimit = 0 AND clean single duration  -> (EndDatetime - StartDatetime) / duration
     4. RuleLimit = 0 AND explicit "Max N" text  -> use N directly (nearest non-date number to "max")
     5. RuleLimit = 0 AND says "max" but no      -> NOT auto-resolved. This is an upstream data gap
        number stated anywhere in the text          (nobody ever configured the real limit) -- report
                                                      to Katybeth's team rather than guess.
     6. Neither                                  -> unlimited (unchanged current behavior)
     

   IMPORTANT SCOPE NOTE
   This should only run against templates already classified FREE_SLOT by
   Stage 1. Several rows in the sample data (Versa1/2/3, Synergy, Tomo,
   Unity, Siemens CT, "LOKICH leave/vacaton", "LUNCH - Hashemi") look like
   they are still landing here because the BLOCKING case-statement
   expansion is in progress -- once that's finished, re-run the triage
   query below, since the eligible row count will likely shrink further.
   ============================================================================ */

------------------------------------------------------------------------
-- 1) Duration extractor: returns NULL on zero OR multiple duration
--    mentions in the same description (ambiguous == don't guess).
--    Requires a digit immediately (optionally via one space) adjacent
--    to "min"/"mins" -- NOT a bare substring match -- specifically to
--    avoid false positives like "Nurse Minor Procedure Room".
--
--    SECOND PATH (confirmed allowlist only): a small set of activity
--    codes are used as bare "<Code><digits>" shorthand with no "min"
--    text at all -- e.g. "OV20" = Office Visit 20 min, "PO15" =
--    Post-Op 15 min (confirmed). This is deliberately an ALLOWLIST of
--    exact prefixes, not a general "letters+digits = duration" rule --
--    "OR 1"/"OR 2"/"OR 3" (Operating Room) and "Procedure 1"/"Procedure 2"
--    are the same shape but mean something entirely different. Do NOT
--    add a new prefix to @ShorthandPrefixes without an explicit
--    confirmation like the OV/PO one, or this will misparse rows like
--    those.
------------------------------------------------------------------------


    DECLARE @i INT = 1;
    DECLARE @Len INT = LEN(@Description);
    DECLARE @Result INT = NULL;
    DECLARE @FoundCount INT = 0;

    WHILE @i <= @Len - 2
    BEGIN
        IF SUBSTRING(@Description, @i, 3) = 'min'   -- default collation is case-insensitive
        BEGIN
            DECLARE @j INT = @i - 1;
            IF @j >= 1 AND SUBSTRING(@Description, @j, 1) = ' '
                SET @j = @j - 1;                     -- allow exactly one space: "20 min" vs "20min"

            DECLARE @DigitEnd INT = @j;
            WHILE @j >= 1 AND SUBSTRING(@Description, @j, 1) LIKE '[0-9]'
                SET @j = @j - 1;
            DECLARE @DigitStart INT = @j + 1;

            IF @DigitStart <= @DigitEnd   -- found a digit run immediately before "min"
            BEGIN
                SET @FoundCount = @FoundCount + 1;
                IF @FoundCount = 1
                    SET @Result = CAST(SUBSTRING(@Description, @DigitStart, @DigitEnd - @DigitStart + 1) AS INT);
                ELSE
                    SET @Result = NULL;   -- second duration mention found -> ambiguous, refuse to guess
                                           -- (e.g. "NP/CCIR 60 min OV/PC 30min")
            END
        END
        SET @i = @i + 1;
    END

    -- Second path: confirmed bare-shorthand prefixes only (allowlist).
    -- Only applied if the "min"-text scan above found nothing, and only
    -- when the ENTIRE trimmed description is exactly "<Prefix><digits>"
    -- -- not merely contains it -- to avoid matching a shorthand code
    -- embedded inside a longer, unrelated description.
    IF @Result IS NULL
    BEGIN
        DECLARE @Trimmed NVARCHAR(200) = LTRIM(RTRIM(@Description));
        DECLARE @Rest NVARCHAR(200);

        IF (@Trimmed LIKE 'OV[0-9]%' OR @Trimmed LIKE 'OV [0-9]%')
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF (@Trimmed LIKE 'PO[0-9]%' OR @Trimmed LIKE 'PO [0-9]%' OR @Trimmed LIKE 'PO only [0-9]%') 
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF @Trimmed LIKE 'NP[0-9]%'     -- confirmed: PO<N> = Post-Op N min
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF (@Trimmed LIKE 'PC[0-9]%' OR @Trimmed LIKE 'PC [0-9]%')    -- confirmed: PO<N> = Post-Op N min
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF (@Trimmed LIKE 'NP/IR[0-9]%' OR @Trimmed LIKE 'NP/IR [0-9]%')
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF ( @Trimmed LIKE 'NP/CCIR[0-9]%' OR @Trimmed LIKE 'NP/CCIR [0-9]%')
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF (@Trimmed LIKE 'OP[0-9]%' OR @Trimmed LIKE 'OP [0-9]%')
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF (@Trimmed LIKE 'TV[0-9]%' OR @Trimmed LIKE 'TV [0-9]%' 
               or @Trimmed LIKE 'televisit [0-9]%')
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF ( @Trimmed LIKE 'clinic[0-9]%' OR @Trimmed LIKE 'clinic [0-9]%')
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF ( @Trimmed LIKE 'Mid-Level[0-9]%' OR @Trimmed LIKE 'Mid-Level [0-9]%'
                  OR @Trimmed LIKE 'APP[0-9]%' OR @Trimmed LIKE 'APP [0-9]%')
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        ELSE IF ( @Trimmed LIKE 'Chemo[0-9]%' OR @Trimmed LIKE 'Chemo [0-9]%')
        BEGIN
            SET @Rest = SUBSTRING(@Trimmed, 3, LEN(@Trimmed) - 2);
            IF PATINDEX('%[^0-9]%', @Rest) = 0
                SET @Result = CAST(@Rest AS INT);
        END
        -- Do not add further prefixes here without explicit confirmation --
        -- e.g. "OR 1"/"OR 2"/"OR 3" and "Procedure 1"/"Procedure 2" are the
        -- same shape and would misparse as 1-minute/2-minute durations.
    END

    RETURN @Result;
END


-- Run this to see the actual breakdown before trusting any tier:
-- SELECT DerivationTier, COUNT(*) AS N FROM dbo.vw_TemplateCapacityTriage GROUP BY DerivationTier ORDER BY N DESC;
-- SELECT * FROM dbo.vw_TemplateCapacityTriage WHERE DerivationTier = 'NEEDS_CONFIGURED_LIMIT';  -- report this list to Katybeth's team
-- SELECT * FROM dbo.vw_TemplateCapacityTriage WHERE DerivationTier = 'NEEDS_REVIEW';
--
-- Separately (outside this view): rows like "Thammineni Out of Office 10/11-14"
-- and "Ward Attending - Thammineni November 2021" have no "max"/"min" keyword
-- at all, so they land safely in STAYS_UNLIMITED here -- but they read like
-- leave/out-of-office entries that may be misclassified as FREE_SLOT rather
-- than BLOCKING at Stage 1. Worth a separate pass once the BLOCKING
-- case-statement expansion is further along, rather than folding into this
-- capacity logic. No newline at end of file