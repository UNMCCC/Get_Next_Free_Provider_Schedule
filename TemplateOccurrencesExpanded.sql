USE [ourStagingDb]
GO

/****** Object:  Table [dbo].[TemplateOccurrencesExpanded]    Script Date: 8/26/2026 2:02:57 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[TemplateOccurrencesExpanded](
	[TemplatePK] [int] NOT NULL,
	[Staff_Staff_ID] [int] NULL,
	[Activity] [nvarchar](200) NULL,
	[TemplateType] [int] NULL,
	[Block_Type] [varchar](20) NULL,
	[Priority] [int] NULL,
	[TemplRule] [int] NULL,
	[RuleLimit] [int] NULL,
	[StartDatetime] [datetime2](0) NOT NULL,
	[EndDatetime] [datetime2](0) NOT NULL
) ON [PRIMARY]
GO


