USE [MosaiqAdmin]
GO

/****** Object:  StoredProcedure [dbo].[sp_RefreshFreeSlotsDatamart]    Script Date: 9/8/2026 3:48:07 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO


CREATE PROCEDURE [dbo].[sp_RefreshFreeSlotsDatamart]
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


