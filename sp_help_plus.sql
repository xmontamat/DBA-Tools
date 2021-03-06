IF EXISTS(SELECT 1 FROM sys.procedures WHERE schema_id = SCHEMA_ID('dbo') AND name = 'sp_help_plus')
      DROP PROCEDURE [dbo].[sp_help_plus]
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
Title : Give Details about an object (similar to sys.sp_help)

Supported object types for now :
	- Tables, Views
	- Synonyms
	- Procs, Functions

History:
	2017-08-23 - XMO - Change proc stats frequency display
	2017-07-31 - XMO - Change behavior for synonyms. Recursive call
	2017-07-11 - XMO - Add dependencies list and @Fast param
	2017-04-12 - XMO - Add row counts for IFs and partioned tables graphs
	2017-03-02 - XMO - Change FK display, proc params, modifyDates
	2016-11-03 - XMO - Add proc params, query_plan, and some columns infos
	2016-08-26 - XMO - Add Constraints and type_tables
	2016-07-11 - XMO - Rework on queries generation
	2016-06-27 - XMO - Add Index Usages stats
	2016-06-10 - XMO - Add dm procs stats
	2016-05-24 - XMO - Add index sizes and Partition tables
	2016-04-19 - XMO - Add Functions, Views
	2016-04-18 - XMO - Add IX - temptables
	2016-04-15 - XMO - Add FKs - DFs - PK/UQ
	2016-04-14 - XMO - Creation
*/
CREATE PROCEDURE [dbo].[sp_help_plus]
(
	@ObjectName sysname = NULL
	,@SelectTop VARCHAR(5) = 2 --> Using a top 2 will select the earliest and latest lines in the table
	,@Fast BIT = 1 --> Faster mode by default, set to 0 to add more infos but with slower response time
	,@Debug BIT = 0
)
AS
BEGIN TRY
SET NOCOUNT ON;
IF @ObjectName IS NULL  BEGIN SELECT 'Select something.' AS Error; RETURN; END;
DECLARE @OriginalObjectName SYSNAME = @ObjectName
	, @SchemaName SYSNAME
	, @DbName SYSNAME
	, @ObjectFullName SYSNAME

SELECT @DbName = [db_name]
,@SchemaName = [schema_name]
,@ObjectName = [object_name]
,@ObjectFullName = [object_fullname] --> the schema and fullname will eventually be updated after the first query
FROM DBA.dbo.FormatObjectName (@OriginalObjectName)

IF @ObjectFullName IS NULL BEGIN
	SELECT 'ERROR trying to format the @ObjectName : '+@ObjectName+' AS DbName.SchemaName.ObjectName.' AS ERROR
	RETURN
END

DECLARE @USE_DB_Str NVARCHAR(50) = CASE WHEN  @DbName != '' AND @DbName!=DB_NAME() THEN 'USE '+QUOTENAME(@DbName)+';'+CHAR(10) ELSE '' END

DECLARE @ExecSQL NVARCHAR(max) = ''

--Search the object and get its objectId and ObjectType
SET @ExecSQL =@USE_DB_Str+'	
SELECT TOP 1 
@ObjectIdOUT=	 o.object_id
,@ObjectTypeOUT= o.type_desc
,@SchemaNameOUT= COALESCE(tts.name, s.name)
,@DbNameOUT=	 DB_NAME()
,@IS_systemOUT=  CASE WHEN oo.object_id IS NOT NULL THEN 0 ELSE 1 END
,@CreateDateOUT= o.create_date
,@ModifyDateOUT= o.modify_date
FROM sys.all_objects AS o
INNER JOIN sys.schemas AS s on o.schema_id = s.schema_id
LEFT JOIN sys.objects AS oo ON oo.object_id = o.object_id
LEFT JOIN sys.table_types AS tt ON o.object_id = tt.type_table_object_id
LEFT JOIN sys.schemas AS tts ON tts.schema_id = tt.schema_id
WHERE (o.name = @ObjectName '
	+CASE WHEN @DbName = 'tempDb' THEN ' OR o.name LIKE @ObjectName+"[_]%"' 
	ELSE 'OR tt.name = @ObjectName'
	END
	+')
'+CASE WHEN @OriginalObjectName LIKE '%.%' THEN ' AND @SchemaName IN(s.name, tts.name)' ELSE ''END
+'
ORDER BY s.schema_id asc, o.create_date desc
'

DECLARE @ObjectType sysname 
		, @ObjectId INT 
		, @IS_system BIT 
		, @CreateDate DATETIME2(0)
		, @ModifyDate DATETIME2(0)
	
SET @ExecSQL = REPLACE(@ExecSQL, '"', '''');
IF @debug = 1 SELECT 'DECLARE @ObjectName sysname = '''+@ObjectName+'''		,@SchemaName sysname = '''+@SchemaName+'''; '+@ExecSQL  AS debug_search_object
EXEC sp_executesql @ExecSQL
	,N'	@ObjectTypeOUT sysname OUTPUT
		,@ObjectIdOUT INT OUTPUT
		,@SchemaNameOUT sysname OUTPUT
		,@DbNameOUT sysname OUTPUT
		,@IS_systemOUT bit OUTPUT
		,@CreateDateOUT DATETIME2(0) OUTPUT
		,@ModifyDateOUT DATETIME2(0) OUTPUT
		,@ObjectName sysname
		,@SchemaName sysname
		,@ObjectId INT
		,@ObjectFullName sysname
		,@DbName sysname
	'
	,@ObjectTypeOUT = @ObjectType OUTPUT
	,@ObjectIdOUT	= @ObjectId OUTPUT
	,@SchemaNameOUT = @SchemaName OUTPUT
	,@DbNameOUT = @DbName OUTPUT
	,@IS_systemOUT = @IS_system OUTPUT
	,@CreateDateOUT = @CreateDate OUTPUT
	,@ModifyDateOUT = @ModifyDate OUTPUT
	,@ObjectName = @ObjectName
	,@SchemaName = @SchemaName 
	,@ObjectId = @ObjectId
	,@ObjectFullName = @ObjectFullName
	,@DbName = @DbName



IF @ObjectType IS NULL OR @ObjectId IS NULL BEGIN
	SELECT 'Object not found in current DB.' AS [Not found]
	RETURN
END

--Reset the full name AS the schema could have change
SET @ObjectFullName = @DbName+'.'+@SchemaName+'.'+@ObjectName

-- Debug string to be added in front of ExecSql only in case of Debug
DECLARE @DebugExecSQL NVARCHAR(500) =
'
DECLARE @ObjectName sysname = '''+@ObjectName+'''
		,@SchemaName sysname = '''+@SchemaName+'''
		,@ObjectId INT = '+CAST(@ObjectId AS VARCHAR(50))+'
		,@ObjectFullName sysname = '''+@ObjectFullName+'''
		,@ObjectType sysname = '''+@ObjectType+'''
		;
'

------------------------------------------------------------------------------
--------------------------------SYNONYMS--------------------------------------
------------------------------------------------------------------------------
IF @ObjectType = 'SYNONYM'
BEGIN
	SET @ExecSQL =@USE_DB_Str
	DECLARE @synonym_object_name SYSNAME
	SET @ExecSQL +='
	SELECT @synonym_object_nameOUT= s.base_object_name
	FROM sys.synonyms AS s
	WHERE object_id = @ObjectId
	'
	IF @debug = 1 SELECT @DebugExecSQL+@ExecSQL AS debug_query
	EXEC sp_executesql @ExecSQL
			,N'@synonym_object_nameOUT SYSNAME OUTPUT
			,@ObjectId INT'
			,@synonym_object_nameOUT = @synonym_object_name OUTPUT
			,@ObjectId = @ObjectId
	SELECT 
		@ObjectFullName AS [SYNONYM]
		,@synonym_object_name AS [Synonym_Definition					]

	--Recall this proc but for the object's synonym
	EXEC sp_help_plus @ObjectName = @synonym_object_name, @SelectTop = @SelectTop, @Fast = @Fast, @Debug= @Debug
	RETURN
END
------------------------------------------------------------------------------
--------------------------------TABLES----------------------------------------
------------------------------------------------------------------------------
IF @ObjectType IN('USER_TABLE', 'SYSTEM_TABLE', 'VIEW', 'SYNONYM') BEGIN
SET @ExecSQL =@USE_DB_Str

--Display Stats on the Table Like nb_rows, size, description, and some infos used later
SET @ExecSQL +='

-- Size calculation technique from sp_spaceused
DECLARE @primary_pages	bigint	,@reservedpages  bigint	,@usedpages  bigint	,@rowCount bigint
SELECT 
	 @reservedpages = SUM (total_pages),
	 @usedpages = SUM (used_pages),
	 @primary_pages = SUM (
		CASE
			WHEN (index_id < 2) THEN 
				CASE 
					WHEN au.type = 1 THEN data_pages --> IN_ROW_DATA
					WHEN au.type > 1 THEN used_pages --> LOB_DATA & ROW_OVERFLOW_DATA
				END
			ELSE 0
		END),
	 @rowCount = SUM (
		CASE
			WHEN (index_id < 2 AND au.type = 1) THEN p.rows
			ELSE 0
		END)
FROM sys.partitions AS p
INNER JOIN sys.allocation_units AS au ON p.hobt_id = au.container_id
WHERE p.object_id = @ObjectId

DECLARE @TableDescr sql_variant = (
SELECT TOP 1 value FROM sys.extended_properties AS ext WITH(NOLOCK)
WHERE ext.major_id = @ObjectId AND ext.minor_id = 0)

SELECT 
	@ObjectFullName AS ['+@ObjectType+']
	,nb_rows =  FORMAT(@rowCount ,"##,##0")
	,reserved_space = FORMAT(@reservedpages * 8 ,"##,##0")+" KB"
	,data_size = FORMAT(@primary_pages * 8 ,"##,##0")+" KB"
	,index_size = FORMAT((CASE WHEN @usedpages > @primary_pages THEN (@usedpages - @primary_pages) ELSE 0 END) * 8 ,"##,##0")+" KB"
	--,unused_space = FORMAT((CASE WHEN @reservedpages > @usedpages THEN (@reservedpages - @usedpages) ELSE 0 END) * 8 ,"##,##0")+" KB"
	,@TableDescr AS [Table Description									]
	,@ObjectId AS ObjectID
	'+CASE WHEN @DbName = 'TempDB' THEN ',"IF OBJECT_ID(""tempdb..'+@ObjectName+'"") IS NOT NULL DROP TABLE '+@ObjectName+';" AS [Drop statement]' ELSE '' END+'
	,@CreateDate AS CreationDate
	,@ModifyDate AS ModifyDate

--Get Clustered columns for reliant Order By in the next Query
SELECT @PK_columnsOUT =(
SELECT 
CASE 
	WHEN ic.key_ordinal!= 1 THEN "," ELSE ""
END +
QUOTENAME(c.name)+
CASE 
	WHEN ic.is_descending_key = 0 THEN " ASC" ELSE " DESC"
END
AS [text()]
FROM sys.indexes AS i
INNER JOIN sys.index_columns AS ic
	ON ic.object_id = i.object_id AND ic.index_id = i.index_id
INNER JOIN sys.columns AS c
	ON c.object_id = i.object_id AND c.column_id = ic.column_id
WHERE	i.object_id = @ObjectId
AND		type_desc = "CLUSTERED"
ORDER BY ic.key_ordinal
FOR XML PATH("")
) 

-- Check if the table has some partitioned indexes
SELECT @Is_partitionedOUT  = (
SELECT TOP 1 1 
FROM		sys.indexes AS i 
INNER JOIN	sys.partition_schemes AS ps ON i.data_space_id = ps.data_space_id
INNER JOIN	sys.partition_functions AS pf ON pf.function_id = ps.function_id
WHERE i.object_id = @ObjectId
)
'

DECLARE @PK_columns VARCHAR(512) = NULL
DECLARE @Is_partitioned BIT = 0

SET @ExecSQL = REPLACE(@ExecSQL, '"', '''');
IF @IS_system = 1 BEGIN
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.objects', 'sys.system_objects');
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.columns', 'sys.system_columns');
END
IF @debug = 1 SELECT @DebugExecSQL+@ExecSQL AS debug_query
EXEC sp_executesql @ExecSQL
		,N'	@PK_columnsOUT VARCHAR(512) OUTPUT
			,@Is_partitionedOUT BIT OUTPUT
			,@ObjectId INT
			,@ObjectFullName sysname
			,@CreateDate DATETIME2(0)
			,@ModifyDate DATETIME2(0)
		'	
		,@PK_columnsOUT = @PK_columns OUTPUT
		,@Is_partitionedOUT = @Is_partitioned OUTPUT
		,@ObjectId = @ObjectId
		,@ObjectFullName = @ObjectFullName
		,@CreateDate = @CreateDate
		,@ModifyDate = @ModifyDate


SET @ExecSQL =@USE_DB_Str

--Extract a few rows FROM the table
IF @SelectTop = 2 AND @PK_columns IS NOT NULL
-- Default. Will return the first and last rows if @SelectTop = 2, UNION ALL avoids performance issues (ordered by clustered columns found previously). Can't be done with no PK
SET @ExecSQL+='
SELECT * FROM ( 
SELECT TOP (1) * FROM @ObjectFullName WITH(NOLOCK)
ORDER BY '+@PK_columns+'
) asc_
UNION ALL
SELECT * FROM ( 
SELECT TOP (1) * FROM @ObjectFullName WITH(NOLOCK)
ORDER BY '+REPLACE(REPLACE(@PK_columns, ' DESC', ''), ' ASC', ' DESC')+'
) desc_ '
ELSE -- IF @SelectTop = xx (or no PK found), selects top xx rows ORDER DESC
SET @ExecSQL+='
SELECT top '+@SelectTop+' * FROM @ObjectFullName WITH(NOLOCK)
'+ISNULL(
'ORDER BY '+REPLACE(REPLACE(@PK_columns, ' DESC', ''), ' ASC', ' DESC')
, '')

SET @ExecSQL = REPLACE(@ExecSQL, '"', '''');
IF @IS_system = 1 BEGIN
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.objects', 'sys.system_objects');
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.columns', 'sys.system_columns');
END
SET @ExecSQL = REPLACE(@ExecSQL, '@ObjectFullName', @ObjectFullName)
IF @debug = 1 SELECT @DebugExecSQL+@ExecSQL AS debug_query
EXEC sp_executesql @ExecSQL

END
IF @ObjectType IN('USER_TABLE', 'SYSTEM_TABLE', 'VIEW', 'TYPE_TABLE') BEGIN

--Extract Table data for all columns
--This query is more than 4K chars so it needs the N' everywhere. Some variables are inserted with replace() at the end

SET @ExecSQL =@USE_DB_Str +N'

-- Display All Columns details
SELECT	
	c.column_id AS ID
	,c.name
	+
	+CASE 
		WHEN PK_UQ.type = "PK"
			THEN " /*PK*/"
		WHEN PK_UQ.type = "UQ" AND MAX(key_ordinal) OVER(PARTITION BY PK_UQ.name) = 1
			THEN " /*UQ*/"
		WHEN PK_UQ.type = "UQ" AND MAX(key_ordinal) OVER(PARTITION BY PK_UQ.name) > 1
			THEN " /*UQ ["+CAST(PK_UQ.key_ordinal AS VARCHAR(2))+"/"+CAST(MAX(key_ordinal) OVER(PARTITION BY PK_UQ.name) AS VARCHAR(2))+"]*/"
		ELSE ""
	END
	+CASE WHEN c.is_identity = 1 THEN " ("+CAST(idc.seed_value AS VARCHAR)+","+CAST(idc.increment_value AS VARCHAR)+")"
		ELSE ""
	END
	 AS [column_name		]
	,CASE
		WHEN (t.name LIKE "%VARCHAR" OR t.name LIKE "%binary") AND c.max_length = -1  THEN t.name+"(max)"
		WHEN t.name IN ("CHAR", "VARCHAR", "BINARY", "VARBINARY")  THEN t.name+"("+CAST(c.max_length   AS VARCHAR(4))+")" 
		WHEN t.name = "NVARCHAR" THEN t.name+"("+CAST(c.max_length/2 AS VARCHAR(4))+")" 
		WHEN t.name = "DATETIME2" THEN t.name+"("+CAST(c.scale AS VARCHAR(1))+")"
		WHEN t.name IN ("DECIMAL", "NUMERIC") THEN t.name+"("+CAST(c.precision AS VARCHAR(2))+","+CAST(c.scale AS VARCHAR(2))+")"
		ELSE t.name
	END 
	+ CASE WHEN c.collation_name IS NULL OR c.collation_name = "Latin1_General_CI_AI" THEN ""
		ELSE " COLLATE "+c.collation_name
	END AS column_type
	,CASE c.is_nullable WHEN 1 THEN "NULL" ELSE "NOT NULL" END AS nullable
	,ISNULL(comp.definition+CASE WHEN is_persisted = 1 THEN " PERSISTED" ELSE "" END , "") AS [computed?]
	,ISNULL(ext.value, "") AS [Description									]
	,ISNULL(SUBSTRING(df.definition, 2, LEN(df.definition)-2), "") AS [Default]
	,ISNULL(FK_references.FKs_list, "") AS FKs_Ref_To
	,ISNULL(FK_ReferredBy.FKs_list, "") AS FKs_RefedBy_list'
IF @Fast =0 BEGIN
SET @ExecSQL +='
	,ISNULL(DependsOn.DependsOn_list , "") AS Dependencies_list'
END
SET @ExecSQL +='
	,ISNULL("CONSTRAINT "+df.name+ " DEFAULT ", "")
	+ISNULL(SUBSTRING(df.definition, 2, LEN(df.definition)-2), "")
	AS DF_Key_String
FROM sys.columns AS c
INNER JOIN sys.types AS t
	ON t.system_type_id = c.system_type_id AND t.user_type_id = c.user_type_id
LEFT JOIN sys.extended_properties AS ext
	ON ext.major_id = @ObjectId AND ext.minor_id = c.column_id
LEFT JOIN sys.computed_columns AS comp
	ON c.is_computed = 1 AND comp.object_id = @ObjectId AND comp.column_id = c.column_id
LEFT JOIN sys.default_constraints AS df
	ON df.parent_object_id = @ObjectId AND df.parent_column_id = c.column_id
LEFT JOIN sys.identity_columns AS idc
	ON c.is_identity = 1 AND idc.object_id = @ObjectId AND c.column_id = idc.column_id
OUTER APPLY (
	SELECT (
	SELECT  (CASE FK.is_disabled WHEN 1 THEN "/*DISABLED*/ " ELSE "" END)
			+CASE WHEN ref_schema.name != "dbo" THEN ref_schema.name+"." ELSE "" END 
			+ref_table.name+" ("+ref_column.name+")"
			+" -- "+FK.name
			+CHAR(10)
			AS [text()]
	FROM sys.foreign_key_columns as FKC
	INNER JOIN sys.foreign_keys AS FK ON FKC.constraint_object_id = FK.object_id 
	INNER JOIN sys.objects AS ref_table ON ref_table.object_id = FKC.referenced_object_id
	INNER JOIN sys.schemas AS ref_schema ON ref_table.schema_id = ref_schema.schema_id
	INNER JOIN sys.columns AS ref_column ON ref_column.object_id = FKC.referenced_object_id AND ref_column.column_id = FKC.referenced_column_id
	WHERE	FKC.parent_object_id = @ObjectId 
	AND		FKC.parent_column_id = c.column_id
	For XML PATH ("")
	) FKs_list
) FK_references --Get the details if this column refers to others
OUTER APPLY (
	SELECT (
	SELECT  (CASE FK.is_disabled WHEN 1 THEN "/*DISABLED*/ " ELSE "" END)
			+CASE WHEN ref_schema.name != "dbo" THEN ref_schema.name+"." ELSE "" END 
			+ref_table.name+" ("+ref_column.name+")"
			+" -- "+FK.name
			+CHAR(10)
			AS [text()]
	FROM sys.foreign_key_columns as FKC
	INNER JOIN sys.foreign_keys AS FK ON FKC.constraint_object_id = FK.object_id 
	INNER JOIN sys.objects AS ref_table ON ref_table.object_id = FKC.parent_object_id
	INNER JOIN sys.schemas AS ref_schema ON ref_table.schema_id = ref_schema.schema_id
	INNER JOIN sys.columns AS ref_column ON ref_column.object_id = FKC.parent_object_id AND ref_column.column_id = FKC.parent_column_id
	WHERE	FKC.referenced_object_id = @ObjectId 
	AND		FKC.referenced_column_id = c.column_id
	For XML PATH ("")
	) AS FKs_list
) AS FK_ReferredBy --Get the list of FKs if this column is referred by others
OUTER APPLY(
	SELECT PK_UQ.name
		,CASE PK_UQ.type_DESC
			WHEN "PRIMARY_KEY_CONSTRAINT" THEN "PK"
			WHEN "UNIQUE_CONSTRAINT" THEN "UQ"
			ELSE "unknown"
		END AS type
		,PK_UQ_c.key_ordinal
		--,(SELECT MAX(key_ordinal) FROM sys.index_columns WHERE PK_UQ_c.object_id = @ObjectId AND  PK_UQ_c.column_id = c.column_id) AS max_key_ordinal
	FROM sys.index_columns AS PK_UQ_c 
	INNER JOIN sys.key_constraints AS PK_UQ 
		ON PK_UQ.parent_object_id = @ObjectId AND PK_UQ_c.index_id = PK_UQ.unique_index_id
	WHERE PK_UQ_c.object_id = @ObjectId AND  PK_UQ_c.column_id = c.column_id
) AS PK_UQ
'
IF @Fast =0 BEGIN
SET @ExecSQL +='
OUTER APPLY(
	SELECT (
	SELECT  
			CASE WHEN DependO.type = "P" THEN "PROC" ELSE DependO.type_desc END
			+": "+OBJECT_NAME(DependO.object_id) 
			+" "+CASE WHEN d.is_updated = 1
				THEN "(WRITE)"
				WHEN d.is_select_all = 1 OR d.is_selected = 1
				THEN "(READ)"
			END 
			+CHAR(10)
			AS [text()]
		FROM sys.sql_dependencies d WITH (NOLOCK) 
		LEFT JOIN sys.objects DependO WITH (NOLOCK)
			ON d.object_id = DependO.object_id 
		WHERE d.referenced_major_id = @ObjectId
			AND (d.referenced_minor_id = c.column_id 
				OR d.referenced_minor_id = 0 -- means all columns
				)
		ORDER BY DependO.type, d.is_updated DESC
	For XML PATH ("")
	) AS DependsOn_list
) AS DependsOn --Get the list of objects that depends on this column, like procs, views (not FKs)
'
END
SET @ExecSQL +='
WHERE	c.object_id = @ObjectId
ORDER BY c.column_id
'

SET @ExecSQL = REPLACE(@ExecSQL, '"', '''');
IF @IS_system = 1 BEGIN
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.objects', 'sys.system_objects');
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.columns', 'sys.system_columns');
END
IF @debug = 1 SELECT @DebugExecSQL+@ExecSQL AS debug_query
EXEC sp_executesql @ExecSQL
		,N' @ObjectId INT
		'	
		,@ObjectId = @ObjectId

		
IF @ObjectType NOT IN('VIEW', 'TYPE_TABLE') BEGIN --Add Indexes or tables

SET @ExecSQL =@USE_DB_Str +N'
SELECT i.name AS Index_Name
	,Indexed_Columns.Names AS Indexed_Columns
	,CASE WHEN is_primary_key = 1 THEN "PRIMARY KEY"
	ELSE CASE WHEN i.is_unique = 1 THEN "[UQ] " ELSE "" END
	+COALESCE("WHERE "+SUBSTRING(i.filter_definition, 2, LEN(i.filter_definition)-2), i.type_DESC collate Latin1_General_CI_AI)
	END AS [Index_Type   ]
	,FORMAT(Index_sizes.used_page_count * 8 ,"##,##0")+" KB"
	+CASE WHEN i.filter_definition IS NOT NULL THEN " ("+FORMAT(Index_sizes.TotalRows,"##,##0")+" rows)" ELSE "" END
	 AS Index_Size
	,i.fill_factor AS Fill_F
	,CASE data_compression 
		WHEN 0 THEN "NONE"
		WHEN 1 THEN "ROW"
		WHEN 2 THEN "PAGE"
	END AS Compress
	,ds.name AS Location
	'
IF (SELECT HAS_PERMS_BY_NAME(null, null, 'VIEW SERVER STATE')) = 1
SET @ExecSQL+=N'
	,CAST(IXStats.user_seeks AS VARCHAR)+" Seeks , "
	+CAST(IXStats.user_scans AS VARCHAR)+" Scans , "
	+CAST(IXStats.user_lookups AS VARCHAR)+" Lookups"
	AS Index_Usage
	,CAST(last_user_read AS DATETIME2(0)) AS Last_Read
	'
IF @Is_partitioned = 1 
SET @ExecSQL+=N'
	, pf.name+''(''+pf_column.name+'')'' AS Part_Function
	, prv.range AS Current_part_range
'
SET @ExecSQL+=N'
FROM sys.indexes AS i 
INNER JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
OUTER APPLY
(
SELECT( 
	SELECT
	CASE 
		WHEN key_ordinal>1 THEN ", "+ c.name
		WHEN key_ordinal=1 THEN c.name
		WHEN key_ordinal=0 THEN " (+"+c.name+")" --> = 0 means included column
	END
	+ CASE WHEN ic.is_descending_key = 1 THEN " DESC" ELSE "" END
	AS [text()]
	FROM sys.index_columns AS ic
	INNER JOIN sys.columns AS c ON c.object_id = i.object_id AND c.column_id = ic.column_id
	WHERE	ic.index_id = i.index_id
	AND		ic.object_id = i.object_id
	ORDER BY (CASE WHEN ic.key_ordinal = 0 THEN 999 ELSE  ic.key_ordinal END )
	For XML PATH ("")
) AS Names
) AS Indexed_Columns
OUTER APPLY
(
	SELECT	SUM(au0.used_page_count) AS used_page_count,
			MAX(p.data_compression) AS data_compression,
			SUM(p.rows) AS TotalRows
	FROM sys.partitions AS p
		CROSS APPLY (SELECT SUM(used_pages) AS used_page_count FROM sys.allocation_units AS au WHERE p.hobt_id = au.container_id) AS au0
	WHERE	p.object_id = i.object_id
	AND		p.index_id = i.index_id
) AS Index_sizes
'
IF (SELECT HAS_PERMS_BY_NAME(null, null, 'VIEW SERVER STATE')) = 1
SET @ExecSQL+=N'
OUTER APPLY (
	SELECT SUM (IXStats.user_seeks) AS user_seeks
	,SUM(IXStats.user_scans) AS user_scans
	,SUM(IXStats.user_lookups) AS user_lookups
	,(	SELECT MAX(read_dates) 
		FROM (VALUES (MAX(last_user_seek)), (MAX(last_user_scan)), (MAX(last_user_lookup))) AS value(read_dates)
	) AS last_user_read
	FROM sys.dm_db_index_usage_stats AS IXStats
	WHERE	IXStats.object_id = i.object_id
	AND		IXStats.index_id = i.index_id
	AND		IXStats.Database_ID = DB_ID()
) AS IXStats
'
IF @Is_partitioned = 1 
SET @ExecSQL+=N'
LEFT JOIN	sys.partition_schemes AS ps ON i.data_space_id = ps.data_space_id
LEFT JOIN	sys.partition_functions AS pf ON pf.function_id = ps.function_id
LEFT JOIN	sys.index_columns AS pf_icolumn ON pf_icolumn.object_id = i.object_id AND pf_icolumn.index_id = i.index_id AND partition_ordinal > 0
LEFT JOIN	sys.columns AS pf_column ON pf_column.column_id = pf_icolumn.column_id AND pf_column.object_id = i.object_id
OUTER APPLY  (
	SELECT TOP 1 
		ISNULL(CAST(prv1.value AS VARCHAR), "No limit")
		+ " - " 
		+ CAST(prv2.value AS VARCHAR) 
		AS [range]
	FROM  sys.partition_range_values AS prv1
	RIGHT JOIN sys.partition_range_values prv2 
		ON prv2.function_id = prv1.function_id
		AND prv2.boundary_id -1 = prv1.boundary_id 
	RIGHT JOIN sys.partitions AS p2 
		ON p2.object_id = i.object_id
		AND p2.partition_number = prv2.boundary_id
	WHERE prv2.function_id = pf.function_id
		AND p2.rows > 0
	ORDER BY prv2.boundary_id desc
) AS prv
'

SET @ExecSQL+=N'
WHERE i.object_id = @ObjectId
'
SET @ExecSQL = REPLACE(@ExecSQL, '"', '''');
IF @IS_system = 1 BEGIN
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.objects', 'sys.system_objects');
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.columns', 'sys.system_columns');
END
IF @debug = 1 SELECT @DebugExecSQL+@ExecSQL AS debug_query
EXEC sp_executesql @ExecSQL
		,N' @ObjectId INT
		'	
		,@ObjectId = @ObjectId

END --End Indexes details for tables

-- Graph of size repartition for partitioned tables
IF @Is_partitioned = 1 BEGIN
	--Display Partition sizes' repartition
	CREATE TABLE #Graph_FromTable(
		partition_number	INT
		,in_row_data_page_count	INT
		,index_name	sysname
		,Range_Date datetime
		,Range_INT Bigint
		)
	-- depending on the sql_variant type, fill one of the two supported columns
	
	SET @ExecSQL =@USE_DB_Str +'
	INSERT INTO #Graph_FromTable
	SELECT p.partition_number
		, au.in_row_used_page_count / 128 As in_row_data_page_count
		, ISNULL(i.name, ''HEAP'')
		+CASE p.data_compression 
			WHEN 0 THEN '' (NONE)''
			WHEN 1 THEN '' (ROW)''
			WHEN 2 THEN '' (PAGE)''
		END AS index_name
		,CASE 
			WHEN CAST(SQL_VARIANT_PROPERTY(prv.value,"BaseType") AS VARCHAR(10)) LIKE "date%"
				THEN CONVERT(datetime2(0) , prv.value)
		ELSE NULL
		END AS Range_Date
		,p.partition_number AS Range_INT --Big Axis numbers badly managed by graphs
	FROM sys.partitions AS p
	CROSS APPLY(SELECT SUM (used_pages) AS in_row_used_page_count FROM sys.allocation_units AS au WHERE p.hobt_id = au.container_id AND au.type = 1) AS au
	INNER JOIN sys.indexes AS i ON i.index_id = p.index_id AND i.object_id = p.object_id
	INNER JOIN sys.partition_schemes AS ps ON i.data_space_id = ps.data_space_id
	INNER JOIN sys.partition_functions AS pf ON pf.function_id = ps.function_id
	INNER JOIN sys.partition_range_values AS prv ON prv.function_id = pf.function_id AND prv.boundary_id = p.partition_number
	WHERE	p.object_id = @ObjectId
	AND		p.rows>0
	'
		
	SET @ExecSQL = REPLACE(@ExecSQL, '"', '''');
	IF @IS_system = 1 BEGIN
		SET @ExecSQL = REPLACE(@ExecSQL, 'sys.objects', 'sys.system_objects');
		SET @ExecSQL = REPLACE(@ExecSQL, 'sys.columns', 'sys.system_columns');
	END
	IF @debug = 1 SELECT @DebugExecSQL+@ExecSQL AS debug_query
		EXEC sp_executesql @ExecSQL
		,N' @ObjectId INT
		'	
		,@ObjectId = @ObjectId
	
	-- depending on the sql_variant type, one of the two supported columns will not be null
	IF EXISTS (SELECT 1 FROM  #Graph_FromTable WHERE Range_Date IS NOT NULL AND in_row_data_page_count>0)
		EXEC DBA.dbo.Graph_FromTable '#Graph_FromTable', 'Range_Date', 'in_row_data_page_count', 'index_name', @Restrictions= 'Range_Date IS NOT NULL and index_name IS NOT NULL', @Y_DownScaled = 1, @Graph_Title= 'Partitions sizes'' by Date (In MB)'
		
	IF EXISTS (SELECT 1 FROM  #Graph_FromTable WHERE Range_INT IS NOT NULL AND in_row_data_page_count>0)
		EXEC DBA.dbo.Graph_FromTable '#Graph_FromTable', 'Range_INT', 'in_row_data_page_count', 'index_name', @Restrictions= 'Range_INT IS NOT NULL and index_name IS NOT NULL', @Y_DownScaled = 1, @Graph_Title= 'Partitions sizes'' by Partition Number (In MB)'

END --Partition sizes' repartition

END --IF @ObjectType IN USER_TABLE, VIEW...


------------------------------------------------------------------------------
----------------------SQL_STORED_PROCEDURE------------------------------------
------------------------------------------------------------------------------
IF @ObjectType IN('SQL_STORED_PROCEDURE' , 'SQL_TABLE_VALUED_FUNCTION', 'SQL_SCALAR_FUNCTION', 'VIEW', 'EXTENDED_STORED_PROCEDURE', 'SQL_INLINE_TABLE_VALUED_FUNCTION') BEGIN


SET @ExecSQL =@USE_DB_Str +'
IF @ObjectType != "VIEW"
SELECT 
	@ObjectFullName AS ['+@ObjectType+']
	,@ObjectId AS ObjectID
	,@ModifyDate AS ModifyDate
'

SET @ExecSQL+='
--Start Proc Script Creation
DECLARE @proc_def NVARCHAR(max) = "";
'

IF @ObjectType = 'SQL_STORED_PROCEDURE'
	SET @ExecSQL+='
SET @proc_def += 
N"IF EXISTS(SELECT 1 FROM sys.procedures WHERE schema_id = SCHEMA_ID(""'+@SchemaName+'"") AND name = ""'+@ObjectName+'"")
      DROP PROCEDURE ['+@SchemaName+'].['+@ObjectName+']
GO
"'
ELSE IF @ObjectType = 'SQL_TABLE_VALUED_FUNCTION' OR @ObjectType = 'SQL_SCALAR_FUNCTION'
	SET @ExecSQL+='
SET @proc_def += 
N"IF EXISTS(SELECT 1 FROM sys.objects WHERE schema_id = SCHEMA_ID(""'+@SchemaName+'"") AND name = ""'+@ObjectName+'"" AND type IN (""FN"", ""TF"", ""IF""))
      DROP FUNCTION ['+@SchemaName+'].['+@ObjectName+']
GO
"'
ELSE IF @ObjectType = 'VIEW'
	SET @ExecSQL+='
SET @proc_def += 
N"IF EXISTS(SELECT 1 FROM sys.views WHERE schema_id = SCHEMA_ID(""'+@SchemaName+'"") AND name = ""'+@ObjectName+'"")
      DROP VIEW ['+@SchemaName+'].['+@ObjectName+']
GO
"'

SET @ExecSQL+='
SET @proc_def +="
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
"
-- Get Actual Proc Definition (can be on several rows)
DECLARE @Object_Comment NVARCHAR(max) 
DECLARE @colid TINYINT = 0
WHILE @colid < (SELECT MAX(colid) FROM '+CASE WHEN @IS_system = 1 THEN 'master.' ELSE '' END+'sys.syscomments WHERE id = @ObjectId)
BEGIN
	SELECT TOP 1 @colid = colid, @Object_Comment = text  FROM '+CASE WHEN @IS_system = 1 THEN 'master.' ELSE '' END+'sys.syscomments WHERE id = @ObjectId
	AND colid > @colid
	ORDER BY colid ASC
	SET @proc_def+=@Object_Comment
END

IF @proc_def LIKE "%"+CHAR(10) -- > remove last return line if any, because procs and views def are different
	 SET @proc_def = LEFT(@proc_def, LEN(@proc_def)-1)


DECLARE @proc_grants NVARCHAR(max)  = CHAR(10)+"GO

"
-- Add Grants
SET @proc_grants +=ISNULL((
	SELECT (
		Select "GRANT "+p.permission_name+" ON ['+@SchemaName+'].['+@ObjectName+'] TO ["+u.name+"];"+CHAR(10)  AS [text()]
		FROM sys.database_permissions AS p
		INNER JOIN  sys.sysusers AS u ON u.uid = p.grantee_principal_id
		WHERE	major_id = @ObjectId
		ORDER BY u.name
		For XML PATH ("")
	)
)+"GO"
, "")

SET @proc_def += @proc_grants

IF @proc_def IS NULL
	SELECT "Proc def not found" AS Info
ELSE BEGIN
	--SELECT of the Full proc def
	SELECT @proc_def AS [OBJECT_DEF With DBA Template												]

	--PRINT of the previous param. The print is done in batches AS you cannot print more than 4000 chars.
	DECLARE @PrintedChars INT  = 0
		, @LineReturnPosition INT;
	WHILE @PrintedChars <= LEN(@proc_def)
	BEGIN
		--Cannot print blindly every 4K chars to Avoid cutting lines in two
		SET @LineReturnPosition = @PrintedChars+4000 - CHARINDEX ( CHAR(10) , REVERSE( SUBSTRING(@proc_def, @PrintedChars, 4000) )) 
		PRINT SUBSTRING(@proc_def, @PrintedChars, @LineReturnPosition-@PrintedChars)
		SET @PrintedChars= @LineReturnPosition+1
	END
END
'
-- DISPLAY PARAMETERS
SET @ExecSQL+='
--If at least one parameter on the proc, parse the definition to get the parmeters out (with default values unavailable elsewhere)
--! = > Will not display Returned type unless there are some params
IF EXISTS (SELECT 1 FROM sys.all_parameters WITH(NOLOCK) WHERE object_id = @ObjectId)
BEGIN
	DECLARE @proc_params VARCHAR(8000)
	--Remove the first comment part if it exists
	DECLARE @CharIndex INT = CHARINDEX("/*", SUBSTRING(@proc_def, 0 , 300)) 
	IF @CharIndex >0
		SET @CharIndex = CHARINDEX("*/", @proc_def) 
	SET @proc_params = SUBSTRING(@proc_def, @CharIndex+2 /* end of comment part */, 4000)
	SET @CharIndex = CHARINDEX("BEGIN TRY", @proc_params)
	IF @CharIndex > 0 --Begin try found, easy proc with dba template 
		SET @proc_params = SUBSTRING(@proc_params, 0, CHARINDEX("BEGIN TRY", @proc_params))
	ELSE BEGIN--Functions or old procs
		SET @CharIndex = PATINDEX("%[ "+CHAR(9)+CHAR(10)+CHAR(13)+"]BEGIN[ "+CHAR(9)+CHAR(10)+CHAR(13)+"]%", @proc_params)
		SET @proc_params = SUBSTRING(@proc_params, 0, IIF( @CharIndex=0 , 4000, @CharIndex))
	END

	DECLARE @EachLines AS TABLE(id INT, line NVARCHAR(255))
	INSERT INTO @EachLines
	SELECT noligne, val
	FROM DBA.dbo.SplitString(@proc_params, CHAR(10))
	WHERE val LIKE "%@%"

	SELECT sysparams.name AS List
		, EachLines.line AS [Parameters Description                                                                                                       ]  
	FROM sys.all_parameters AS sysparams
	OUTER APPLY (SELECT TOP 1 line
	 FROM @EachLines AS EachLines 
	 WHERE EachLines.line like "%"+sysparams.name+"%"
	 ORDER BY EachLines.id ASC
	) AS EachLines
	WHERE sysparams.object_id = @ObjectId

	IF EXISTS (SELECT 1 
		FROM @EachLines AS EachLines 
		WHERE EachLines.line like "%RETURNS @%"
		)
		SELECT  EachLines.line AS [Returned type]
		FROM @EachLines AS EachLines 
		WHERE EachLines.line like "%RETURNS @%"
END
ELSE SELECT "No parameters" AS Parameters -- This will bypass also returned type if no params. Rare case
'
-- DISPLAY STATISTICS
IF (SELECT HAS_PERMS_BY_NAME(null, null, 'VIEW SERVER STATE')) = 1
SET @ExecSQL+='
-- Display proc''s stats from dm_exec_procedure_stats
IF NOT EXISTS (SELECT TOP 1 1 FROM sys.dm_exec_procedure_stats WHERE object_id = @ObjectId) AND @ObjectType != "VIEW"
	SELECT "No stats found on this proc" AS EmptyStats
ELSE IF @ObjectType != "VIEW"
	SELECT CAST(last_execution_time AS DATETIME2(0))
		AS Last_Exec
		,CASE WHEN Frequency.calls_per_sec >= 1 THEN CAST(FLOOR(Frequency.calls_per_sec) AS VARCHAR(20))+" calls/s" 
			ELSE "1 every "+CAST(FLOOR(1/Frequency.calls_per_sec) AS VARCHAR(50)) + " secs" 
		END +" since "
		+CASE WHEN cached_time< {t''00:00:00''} THEN  LEFT(CAST(cached_time AS VARCHAR(20)), 7) ELSE "" END + SUBSTRING(CAST(cached_time AS VARCHAR(20)), 13,15) 
		AS Frequency
		-- Added the notion of spread multiplicator between the min and max value
		,FORMAT(total_elapsed_time/execution_count ,"##,##0")+"  ("
		+CASE WHEN max_elapsed_time/min_elapsed_time <2 THEN "low spread"
		WHEN max_elapsed_time/min_elapsed_time >=2 THEN CAST(max_elapsed_time/min_elapsed_time AS VARCHAR) +"x spread"
		END
		+") " AS Duration_μs_avg
		-- Added the notion of spread multiplicator the min and max value
		,FORMAT(total_logical_reads/execution_count ,"##,##0")+"  ("
		+CASE WHEN (max_logical_reads+1)/(min_logical_reads+1) <2 THEN "low spread"
		ELSE  CAST((max_logical_reads+1)/(min_logical_reads+1) AS VARCHAR) +"x spread"
		END
		+") " AS Logical_reads_avg
		,CAST(CAST((
			(CAST(total_worker_time AS DECIMAL(38, 12)) / 1000000) /(DATEDIFF(second, cached_time, GETDATE()) * (SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = "VISIBLE ONLINE"))) * 100 
			AS DECIMAL (8,5)) AS VARCHAR(9))+"%" AS CPU_Load
		,FORMAT(total_worker_time / execution_count ,"##,##0") AS CPU_time_avg
		,query_plan AS Cached_query_plan
		,"DBCC FREEPROCCACHE ("+CONVERT(VARCHAR(MAX), plan_handle, 1)+");" AS CleanupPlan
	FROM sys.dm_exec_procedure_stats WITH(NOLOCK)
	OUTER APPLY sys.dm_exec_query_plan(plan_handle)
	OUTER APPLY ( SELECT CAST(execution_count AS DECIMAL(18, 0)) / DATEDIFF(second, cached_time, GETDATE()) AS calls_per_sec ) AS Frequency 
	WHERE object_id = @ObjectId
'

SET @ExecSQL = REPLACE(@ExecSQL, '"', '''');
IF @IS_system = 1 BEGIN
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.objects', 'sys.system_objects');
	SET @ExecSQL = REPLACE(@ExecSQL, 'sys.columns', 'sys.system_columns');
END
IF @debug = 1 SELECT @DebugExecSQL+@ExecSQL AS debug_query
EXEC sp_executesql @ExecSQL
	,N' @ObjectId INT
		,@ObjectFullName sysname
		,@ObjectType sysname
		,@ModifyDate DATETIME2(0)
		'	
		,@ObjectId = @ObjectId
		,@ObjectFullName = @ObjectFullName
		,@ObjectType = @ObjectType
		,@ModifyDate = @ModifyDate


--Add Last XE inserts if any are found
/*
Removed due to delays on this
IF @ObjectType = 'SQL_STORED_PROCEDURE' AND (SELECT HAS_PERMS_BY_NAME('DBA.Temp.XELogs_Rpcs', 'object', 'select')) = 1 --> Only available to DBAs, with select rights
IF EXISTS(SELECT 1 FROM DBA.sys.tables WHERE name = 'XELogs_Rpcs')
BEGIN
	SELECT TOP 2 *
	FROM DBA.Temp.XELogs_Rpcs WITH(NOLOCK, FORCESEEK)
	WHERE Object_name = @ObjectName
	ORDER BY timestamp DESC
END
*/

END -- End Proc/Function @ObjectType

------------------------------------------------------------------------------
-------------------------------CONSTRAINTS------------------------------------
------------------------------------------------------------------------------
IF @ObjectType LIKE '%_CONSTRAINT' BEGIN
	
	SET @ExecSQL =@USE_DB_Str +'
	SELECT 
	@ObjectFullName AS ['+@ObjectType+']
	,@ObjectId AS ObjectID
	,p_s.name+"."+parent.name AS [Parent Table]
	,"IF (SELECT OBJECT_ID("""+@ObjectFullName+""")) IS NOT NULL ALTER TABLE "+p_s.name+"."+parent.name+" DROP CONSTRAINT "+o.name AS [Drop statement]
	FROM sys.objects AS o
	LEFT JOIN sys.objects AS parent ON o.parent_object_id != 0 AND o.parent_object_id = parent.object_id
	LEFT JOIN sys.schemas AS p_s on parent.schema_id = p_s.schema_id
	WHERE o.object_id = @ObjectId
	'
	
	SET @ExecSQL = REPLACE(@ExecSQL, '"', '''');
	IF @debug = 1 SELECT @DebugExecSQL+@ExecSQL AS debug_query
	EXEC sp_executesql @ExecSQL
		,N' @ObjectId INT
		,@ObjectFullName sysname
		,@ObjectType sysname
		'	
		,@ObjectId = @ObjectId
		,@ObjectFullName = @ObjectFullName
		,@ObjectType = @ObjectType

END
ELSE IF @ObjectType NOT IN ('SQL_STORED_PROCEDURE', 'SQL_TABLE_VALUED_FUNCTION', 'SQL_SCALAR_FUNCTION', 'USER_TABLE', 'SYSTEM_TABLE', 'VIEW', 'SYNONYM', 'EXTENDED_STORED_PROCEDURE', 'SQL_INLINE_TABLE_VALUED_FUNCTION') BEGIN
	--All unmanaged types and type_table
	SELECT @ObjectFullName AS OBJECT_NAME, @ObjectType AS OBJECT_TYPE , @ObjectId AS OBJECT_ID
END

END TRY
BEGIN CATCH
	IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
	THROW;
END CATCH
GO

GRANT EXECUTE ON [dbo].[sp_help_plus] TO [public];
GO
