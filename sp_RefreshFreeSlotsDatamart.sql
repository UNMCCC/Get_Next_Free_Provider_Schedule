Use MosaiqAdmin
GO

/* =====================================================================
   dbo.sp_RefreshFreeSlotsDatamart
   =====================================================================
   Orchestrates the full pipeline in the correct dependency order, so
   a single SQL Agent job step can call one proc:
     1) sp_BuildTemplateOccurrences        (recurrence expansion)
     2) sp_BuildProviderEffectiveSchedule  (priority/overlap resolution)
     3) sp_NextFreeSlotsDatamart      (this datamart)

   Suggested SQL Agent schedule: for "at least daily, ideally more
   often," hourly is a reasonable starting point given the tables
   involved are all moderate-sized batch rebuilds (TRUNCATE + INSERT),
   not incremental -- watch actual run time on first few executions
   and adjust frequency if it's cheap enough to run more often, or
   too slow to run hourly.
   ===================================================================== */

IF OBJECT_ID('dbo.sp_RefreshFreeSlotsDatamart', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_RefreshFreeSlotsDatamart;
GO

CREATE PROCEDURE dbo.sp_RefreshFreeSlotsDatamart
    @HorizonDays INT = 120,
    @SlotMinutes INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    EXEC dbo.sp_BuildTemplateOccurrences @HorizonDays = @HorizonDays;
    EXEC dbo.sp_BuildProviderEffectiveSchedule;
    EXEC dbo.sp_NextFreeSlotsDatamart @SlotMinutes = @SlotMinutes;

END
GO