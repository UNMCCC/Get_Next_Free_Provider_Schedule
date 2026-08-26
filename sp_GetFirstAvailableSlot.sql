USE [ourStagingDB]
GO

/****** Object:  StoredProcedure [dbo].[usp_GetFirstAvailableSlot]    Script Date: 8/26/2026 2:07:10 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


------------------------------------------------------------------------
-- 2) STORED PROCEDURE: returns just the FIRST qualifying slot
--    (one row per provider if @Provider is NULL)
------------------------------------------------------------------------
CREATE   PROCEDURE [dbo].[usp_GetFirstAvailableSlot]
    @Provider        NVARCHAR(200) = NULL,
    @SearchFrom      DATETIME2(0)  = NULL,
    @SearchTo        DATETIME2(0)  = NULL,
    @MinGapMinutes   INT           = 75
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Ranked AS (
        SELECT
            g.*,
            rn = ROW_NUMBER() OVER (PARTITION BY g.Provider ORDER BY g.GapStart)
        FROM dbo.fn_FindOpenGaps(@Provider, @SearchFrom, @SearchTo, @MinGapMinutes) g
    )
    SELECT
        Provider,
        FirstAvailableDate = WorkDate,
        GapStart,
        GapEnd,
        GapMinutes
    FROM Ranked
    WHERE rn = 1
    ORDER BY GapStart;

    IF @@ROWCOUNT = 0
        PRINT 'No qualifying open slot found for the given provider(s) and date range.';
END

GO


