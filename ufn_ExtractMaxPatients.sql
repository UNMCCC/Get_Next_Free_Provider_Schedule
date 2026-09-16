
CREATE OR ALTER FUNCTION dbo.ufn_ExtractMaxPatients (@Description NVARCHAR(200))
RETURNS INT
AS
BEGIN
------------------------------------------------------------------------
-- 1b) Explicit "Max N patients" extractor. Real data shows "max" and its
--     number appear in EITHER order ("MAX 10 PTS" vs "5 max pt" vs
--     "9 pts. MAX") and every row also tends to carry an effective-date
--     stamp ("E 8/27", "e-11/5/21", "TT 10.31") whose digits must NOT be
--     mistaken for the count. Strategy:
--       1. Find "max" keyword. If absent, return NULL (not this function's job).
--       2. Scan the whole string for digit runs, excluding any that are
--          date-shaped: immediately preceded by '/' or '.', immediately
--          followed by '/' or '.' then another digit, or immediately
--          preceded (allowing one space/dash) by E/e/TT/tt.
--       3. Of the remaining non-date candidates, take the one CLOSEST
--          (by character distance) to the "max" keyword -- this is
--          deliberately a proximity heuristic, not a "must be adjacent"
--          rule, validated against "max 8 patients 4 OV & 4 NP" (correctly
--          picks 8, the number immediately touching "max", over the two
--          farther-away "4"s that belong to sub-breakdowns).
--       4. If there are NO non-date candidates at all, return NULL --
--          this correctly identifies the large "says max but never
--          states a number" category (e.g. "Max patients E 1/9"), which
--          is a genuine data gap upstream, not something parseable from
--          text -- these need a person to supply the real limit.
------------------------------------------------------------------------
    DECLARE @Text NVARCHAR(200) = @Description;
    DECLARE @Len INT = LEN(@Text);
    DECLARE @MaxPos INT = PATINDEX('%max%', @Text);   -- default collation is case-insensitive
    IF @MaxPos = 0
        RETURN NULL;   -- no "max" keyword present -- not this function's job

    DECLARE @i INT = 1;
    DECLARE @BestValue INT = NULL;
    DECLARE @BestDistance INT = NULL;

    WHILE @i <= @Len
    BEGIN
        IF SUBSTRING(@Text, @i, 1) LIKE '[0-9]'
        BEGIN
            DECLARE @Start INT = @i;
            DECLARE @End INT = @i;
            WHILE @End + 1 <= @Len AND SUBSTRING(@Text, @End + 1, 1) LIKE '[0-9]'
                SET @End = @End + 1;

            DECLARE @IsDate BIT = 0;

            -- date-shaped: followed by '/' or '.' then another digit
            IF @End + 1 <= @Len AND SUBSTRING(@Text, @End + 1, 1) IN ('/', '.')
               AND @End + 2 <= @Len AND SUBSTRING(@Text, @End + 2, 1) LIKE '[0-9]'
                SET @IsDate = 1;

            -- date-shaped: immediately preceded by '/' or '.' (second half of a date)
            IF @IsDate = 0 AND @Start - 1 >= 1 AND SUBSTRING(@Text, @Start - 1, 1) IN ('/', '.')
                SET @IsDate = 1;

            -- date-shaped: preceded (allowing one space/dash) by E/e/TT/tt marker
            IF @IsDate = 0
            BEGIN
                DECLARE @k INT = @Start - 1;
                IF @k >= 1 AND SUBSTRING(@Text, @k, 1) IN (' ', '-')
                    SET @k = @k - 1;
                IF @k >= 1 AND UPPER(SUBSTRING(@Text, @k, 1)) = 'E'
                    SET @IsDate = 1;
                IF @IsDate = 0 AND @k >= 2 AND UPPER(SUBSTRING(@Text, @k - 1, 2)) = 'TT'
                    SET @IsDate = 1;
            END

            IF @IsDate = 0
            BEGIN
                DECLARE @Distance INT = CASE
                    WHEN @Start > @MaxPos THEN @Start - @MaxPos
                    ELSE @MaxPos - @End
                END;
                IF @BestDistance IS NULL OR @Distance < @BestDistance
                BEGIN
                    SET @BestDistance = @Distance;
                    SET @BestValue = CAST(SUBSTRING(@Text, @Start, @End - @Start + 1) AS INT);
                END
            END

            SET @i = @End + 1;
        END
        ELSE
            SET @i = @i + 1;
    END

    RETURN @BestValue;   -- NULL if every digit run in the string was date-shaped (no real count stated)
END
GO

