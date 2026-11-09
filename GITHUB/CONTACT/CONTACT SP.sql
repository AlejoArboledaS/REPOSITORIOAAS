USE [CUN_REPOSITORIO]
GO
/****** Object:  StoredProcedure [Comisiones].[SP_Comisiones_contact]    Script Date: 13/09/2024 3:05:37 p. m. ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
-- Author:		<George,,Galindo>
-- Create date: <11-04-2023>
/* Description:	<Creacion sp de Comisiones del contact, este tiene el fin de pagar las ventas mes vencido, 
                 se realiza pago a mes anterior al actual, teniendo en cuenta, reliquidaciones(Ventas que no pasaron del anterior mes a liquidar),
				 Afectaciones(Son las Reglas del contact para disminuir comision por cumplimiento de indicadores)
				 Pisos de comision(Meta de ventas establecida para liquidacion de ventas)
				 */

-- ==================== BITACORA DE CAMBIOS
-- 1. Se ajusto todo el sp al py de conteos de etiquetas actuales
-- 2. Se ajusto todo el sp al py de conteos de etiquetas reliquidaciones
-- 3. Se ajusto todo el sp al py de subetiquetacion del paso 5
-- 3. Se ajusto todo el sp al py de subetiquetacion del paso 9 (Reliquidaciones)
-- 4. Se arreglo El paso 5 de etiquetacion (ventas actuales) cuando ESTADO PAGO o EST MATRIC son NULL
-- 5. Se arreglo El paso 9 de etiquetacion (ventas RELIQUIDAICONES) cuando ESTADO PAGO o EST MATRIC son NULL
-- 7. Se arreglo el paso 7 de afectaciones con 0.07
-- 8. Se arregla en el paso 5 el cruce con el historico telecampus pero por codigo de unidad
-- 9. Se arregla en el paso 9 (Reliq) el cruce con el historico telecampus pero por codigo de unidad
-- 10. Se migro toda la sub etiquetacion dle paso 5 al py y se acomodo el sp
-- 10. Se migro toda la sub etiquetacion dle paso 9 - Reliq al py y se acomodo el sp

-- =============================================
ALTER PROCEDURE [Comisiones].[SP_Comisiones_contact]

AS
BEGIN

	SET NOCOUNT ON;

---------------------------------------- Paso 1. Crea variable de periodo ---------------------------------------------------------------------------------------------------------------------------
    DECLARE @Ano INT
    DECLARE @Mes INT
    DECLARE @Periodo INT
    DECLARE @Nommes VARCHAR(10)
    DECLARE @NommesAnt VARCHAR(10)

    SET @Ano = DATEPART(YEAR,GETDATE())
    SET @Mes = DATEPART(MONTH,DATEADD(MONTH, -1,GETDATE()))
    SET @Periodo= CASE WHEN @Mes<=9 THEN CAST(@Ano AS VARCHAR)+'0'+CAST(@Mes AS VARCHAR)
        ELSE CAST(@Ano AS VARCHAR) + CAST(@Mes AS VARCHAR) END

    SELECT DISTINCT @Nommes =  Mes FROM cun_repositorio.CUN.Calendario_Anual WHERE periodo = @periodo
    SELECT DISTINCT @NommesAnt = mes FROM cun_repositorio.CUN.Calendario_Anual WHERE num_mes = CASE WHEN @Mes = 1 THEN 12 ELSE @Mes - 1 END
    SELECT @Periodo
    INSERT INTO CUN_REPOSITORIO.dbo.LogControlProcesos (baseDatos, usuario, proceso, registrosAfectados, fechaEjecucion, error)
    SELECT db_name(),user_name(),'sp_ComisionesTelecampus_Var', @@rowcount, getdate(), @@error
---------------------------------------------- Paso 2. Ajuste de fases de zoho, realiza la limpieza para realizar cruce ------------------------------------------------------------------------------------------------------------------------------------
IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ZOHO_FUNELL') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ZOHO_FUNELL

select *,
    case
    when Propietario_de_Fase is null then Propietario
    else Propietario_de_Fase end as
    Propietario_de_Fase_Name
    into CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ZOHO_FUNELL
from(
                select
                     Periodo
                     ,Número_de_Documento
                     ,Correo_electronico_asesor,
				      case when Propietario_de_Oportunidad_Name like '%@%' then substring(Propietario_de_Oportunidad_Name,CHARINDEX(' ', Propietario_de_Oportunidad_Name)+1,50)
                      else Correo_electronico_asesor end Propietario_de_Fase,
                     case when B.Nombre_completo like '%@%' then substring(B.Nombre_completo,CHARINDEX(' ', B.Nombre_completo)+1,50)
                     else B.Correo_electrónico end Propietario,
                     row_number() over (partition by Número_de_Documento,Periodo  order by FechaCreación2 desc ) cont
                from CUN_REPOSITORIO.dbo.zoho_Funell A
                left join zoho.CRM.Usuarios b on a.Propietario_de_Oportunidad = b.ID
                )t1

------------------------------- Paso 3. Trae las ventas de tabla de oracle ya que esta se actualiza en menos tiempo, son mismos datos de tabla de Recibos_Contact ------------------------------------------------------------------------------------------------------------------------------
IF object_id('[tempdb]..[#Ventas]') IS NOT NULL
drop table #Ventas

        SELECT
              *
        into #Ventas
        FROM OPENQUERY([172.16.1.175],
        'select distinct * from iceberg.VEN_VENTAS where ANIO like ''%25%'' ')

--Select top 10* from CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_VENTAS_ORACLE

---------------------------------------------------- Paso 4. Crea la base de ventas para empezar limpieza y calculos, tabla de ventas Contact Vs Ventas Cun------------------------------------------------------------------------------------------------------------------------------------
IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BASE_VENTAS') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BASE_VENTAS
Select t1.*,t2.PERIODO as Periodo_Pago,t3.EST_MATRICULADO,t3.NCR_ANULACION,t3.TIPO,t3.ORDEN,
       t3.VAL_LIQUIDADO,t3.NUEVO,t3.ESTADO_PAGO,t3.Doc_Alum as Documento_Estudiante_zoho
      Into CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BASE_VENTAS
      from Comisiones.Ventas_Contact T1
left join CUN_REPOSITORIO.cun.Calendario_Anual T2 ON CONVERT(date, t1.Fecha_de_pago, 103) = CONVERT(date, t2.FECHA_MES, 103)
Left join (Select * from (
select Doc_Alum,ESTADO_PAGO,NCR_ANULACION,NUEVO,EST_MATRICULADO,PERIODO,ORDEN,VAL_LIQUIDADO,TIPO
        , row_number() over (partition by Doc_Alum,PERIODO  order by ESTADO_PAGO desc,NCR_ANULACION desc, EST_MATRICULADO,ORDEN asc ) cont
                    from #Ventas 	where DOCUMENTO in ( 'FAMA','FECO')  and PERIODO not like '%I%'
                                                                      )t1
                    where cont = 1) t3 on t1.Doc_Estudiante = t3.Doc_Alum and t1.PERIODO = t3.PERIODO
where t2.PERIODO = '202505'



----------------------------------------------------- Paso 5. Se crean las marcas con el cruce realizado anteriormente, para saber con cuales realizar calculos ------------------------------------------------------------------------------------------------------------------------------------

                Delete from  Comisiones_Contact.Etiquetas where Periodo_Pago = '202505'

INSERT INTO Comisiones_Contact.Etiquetas
select *,
            case
             when Motivo =  'OK' THEN 'OK'
             ELSE Motivo END AS EstadoFinal
            from (select distinct t1.*,
                               case
                                   WHEN T3.Doc_Estudiante IS NOT NULL THEN 'YA SE PAGO'
                                   when t1.Documento_Estudiante_zoho is null
                                   then 'No coincide con Iceberg o Sinu'
                                   when t1.ESTADO_PAGO <> 'PAGO' then 'No Registra Pago'
								   when t1.ESTADO_PAGO IS NULL then 'No Registra Pago'
								   when t1.EST_MATRICULADO IS NULL then 'No Registra Matricula'
                                 --  when t1.NCR_ANULACION < 0 then 'Tiene Anulación'
                                   when t1.NUEVO = 'ANTIGUO' and TIPO <> 'Educacion continuada' then 'Estudiante ANTIGUO'
                                   when t1.EST_MATRICULADO <> '1-Activo'
                                   then 'Estado Diferente al Activo ' + t1.EST_MATRICULADO
                                   when t1.VAL_LIQUIDADO < 200000 then 'Valor liquidado Menor 20%'
                                   --when t4.CorreoPersonalSugerido is null then 'Sin Correo Electronico'
                                   --when t4.CelularSugerido is null then 'Sin Telefono personal'
                                   else 'ok' end Motivo,
                               t2.Propietario_de_Fase_Name--,t2.Correo_electronico_asesor
                        from CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BASE_VENTAS t1
                        left join CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ZOHO_FUNELL t2
                                  on t1.Doc_Estudiante = t2.Número_de_Documento and t1.PERIODO = t2.Periodo and
                                     t1.Correo_Asesor = t2.Propietario_de_Fase_Name
                        LEFT JOIN (select distinct Doc_Estudiante,PERIODO from Comisiones_Contact.Etiquetas where EstadoFinal = 'OK') T3
                                  ON T1.Doc_Estudiante = T3.Doc_Estudiante AND T1.PERIODO = T3.PERIODO
                        left join (select * from [Calidad].[Datos_contacto_CUN2]) t4
                                 on t1.Documento_Estudiante_zoho = t4.NUM_IDENTIFICACION

              )t1

------------------------------------------------
--Guardo en una temporal las Etiquetas de este mes
IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ETIQ_ACTUAL_1') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ETIQ_ACTUAL_1

Select*
Into CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ETIQ_ACTUAL_1
FROM CUN_REPOSITORIO.COMISIONES_CONTACT.ETIQUETAS WHERE Periodo_Pago ='202505' and EstadoFinal ='OK'
------------------------------------------------
--borro de etiquetas todas las actuales
DELETE FROM CUN_REPOSITORIO.COMISIONES_CONTACT.ETIQUETAS WHERE Periodo_Pago = '202505' and EstadoFinal ='OK'
------------------------------------------------
IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ETIQ_ACTUAL_1_1') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ETIQ_ACTUAL_1_1

--Ejecutar py de Sub etiquetacion Etiqueta Actual
--Ejecutar py de Sub etiquetacion Etiqueta Actual
--Ejecutar py de Sub etiquetacion Etiqueta Actual
--Ejecutar py de Sub etiquetacion Etiqueta Actual
--------------------------------------------------------------------------------------
--inserto todo nuevamente a Etiquetas 
INSERT INTO CUN_REPOSITORIO.COMISIONES_CONTACT.ETIQUETAS
SELECT * FROM CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ETIQ_ACTUAL_1_1;
--select * from CUN_REPOSITORIO.COMISIONES_CONTACT.ETIQUETAS where Periodo_Pago = '202505'
------------------------------------------- Paso 6. Realiza Conteos con las variables y las reglas de valor por comision, trae tabla etiquetas. --------------------------------------------------------------

IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_CONTEO_VENTAS') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_CONTEO_VENTAS

Delete from Comisiones_Contact.FIJA_LIQ_ACTUAL_DESGLOS where Periodo_Pago = '202505'
Delete from Comisiones_Contact.PREGR_APROB_CONTAC_MOD2 where Periodo_Pago_1 = '202505' 
Delete from Comisiones_Contact.POSG_APROB_CONTAC_MOD2 where Periodo_Pago_1 = '202505' 

--'EJECUTAR EL PYTHON'
--'EJECUTAR EL PYTHON'
--'EJECUTAR EL PYTHON'
--'EJECUTAR EL PYTHON'

------------------------------------------------------ Paso 7. Crea temporal con las afectaciones y los calculos por afectacion, trae tabla cargada manualmente ------------------------------------------------------------------------------------------------------------------------------------
IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_AFECTACIONES') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_AFECTACIONES

     Select *, Calidad_Resultado+Formacion_Resultado+Ventas_Resultado+Adherencia_Resultado+Conversion_Resultado+Productividad_Resultado AS Por_Afectacion
INTO CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_AFECTACIONES
     from(
         Select Documento_del_Asesor,Correo_Asesor,Periodo,
          case when CALIDAD <> 'Cumple' then 0.07 else 0 end as Calidad_Resultado,
          case when [FORMACION ]  <> 'Cumple' then 0.07 else 0 end as Formacion_Resultado,
          case when VENTAS  <> 'Cumple' then 0.07 else 0 end as Ventas_Resultado,
          case when ADHERENCIA  <> 'Cumple' then 0.07 else 0 end as Adherencia_Resultado,
          case when CONVERSION  <> 'Cumple' then 0.07 else 0 end as Conversion_Resultado,
		  case when PRODUCTIVIDAD  <> 'Cumple' then 0.07 else 0 end as Productividad_Resultado
  from CUN_REPOSITORIO.Comisiones_Contact.Afectaciones_Contact)t1
--select *from CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_AFECTACIONES
------------------------------------------- Paso 8. Inicio Reliquidaciones. Extrae ventas que no pasaron mes anterior, y cruza como en el punto 4 contra ventas cun  ------------------------------------------------------------------------------------------------------------------------------------

IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BASE_RELIQUIDACION') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BASE_RELIQUIDACION
Select t1.Doc_Estudiante,t1.PERIODO,t1.Documento_del_Asesor,t1.Propietario_del_registro,t1.Programa_vendido,t1.Correo_Asesor,t1.Periodo_Pago
     ,t3.EST_MATRICULADO,t3.NCR_ANULACION,t3.TIPO,t3.ORDEN,
      t3.VAL_LIQUIDADO,t3.NUEVO,t3.ESTADO_PAGO,t3.Doc_Alum as Documento_Estudiante_zoho
INTO CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BASE_RELIQUIDACION
from Comisiones_Contact.Etiquetas t1
         Left join (Select * from (
select Doc_Alum,ESTADO_PAGO,NCR_ANULACION,NUEVO,EST_MATRICULADO,
          PERIODO,ORDEN,VAL_LIQUIDADO,TIPO
         ,row_number() over (partition by Doc_Alum,PERIODO  order by ESTADO_PAGO desc,NCR_ANULACION desc, EST_MATRICULADO,ORDEN asc ) cont
                    from #Ventas where DOCUMENTO in ( 'FAMA','FECO')  and PERIODO not like '%I%'
                                                                       /* and EST_MATRICULADO = '1-Activo'
	                                                                    and NUEVO = 'NUEVO'
	                                                                    AND NCR_ANULACION = 0
	AND ESTADO_PAGO = 'PAGO'*/)t1 where cont = 1) t3 on t1.Doc_Estudiante = t3.Doc_Alum and t1.PERIODO = t3.PERIODO
         where Periodo_Pago = '202504' and EstadoFinal <> 'ok'

--------------------- Paso 9. Al igual que paso 5, realiza la creacion de las etiquetas pero para reliquidaciones inserta en tabla etiquetasreliquidaciones ------------------------------------------------------------------------------------------------------------------------------------
                 Delete from Comisiones_Contact.EtiquetasReliquidacion where Periodo_Pago = '202504'

INSERT INTO Comisiones_Contact.EtiquetasReliquidacion
select *,
       case
            when Motivo =  'OK' THEN 'OK'
ELSE Motivo END AS EstadoFinal
       from (select distinct t1.*,
                               case

                                   when t1.Documento_Estudiante_zoho is null
                                       then 'No coincide con Iceberg o Sinu'
                                   when t1.ESTADO_PAGO <> 'PAGO' then 'No Registra Pago'
								   when t1.ESTADO_PAGO IS NULL then 'No Registra Pago'
								   when t1.EST_MATRICULADO IS NULL then 'No Registra Matricula'
                                 --  when t1.NCR_ANULACION < 0 then 'Tiene Anulación'
                                   when t1.NUEVO = 'ANTIGUO' and TIPO <> 'Educacion continuada' then 'Estudiante ANTIGUO'
                                   when t1.EST_MATRICULADO <> '1-Activo'
                                       then 'Estado Diferente al Activo ' + t1.EST_MATRICULADO
                                   when t1.VAL_LIQUIDADO < 200000 then 'Valor liquidado Menor 20%'
                                   else 'ok' end Motivo,
                               t2.Propietario_de_Fase_Name--,t2.Correo_electronico_asesor
               from CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BASE_RELIQUIDACION t1
                        left join CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_ZOHO_FUNELL t2
                                  on t1.Doc_Estudiante = t2.Número_de_Documento and t1.PERIODO = t2.Periodo and
                                     t1.Correo_Asesor = t2.Propietario_de_Fase_Name
              )t1
------------------------------------------------
--Guardo en una temporal las Etiquetas de este mes
IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.T_ET_Reliq_ACTUAL_1') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.T_ET_Reliq_ACTUAL_1
Select*
Into CUN_REPOSITORIO.COMISIONES_CONTACT.T_ET_Reliq_ACTUAL_1
FROM CUN_REPOSITORIO.COMISIONES_CONTACT.EtiquetasReliquidacion WHERE Periodo_Pago ='202504' and EstadoFinal ='OK'
------------------------------------------------
--borro de etiquetas todas las actuales
DELETE FROM CUN_REPOSITORIO.COMISIONES_CONTACT.EtiquetasReliquidacion WHERE Periodo_Pago = '202504' and EstadoFinal ='OK'
--------------------------------------------------------------------------------------
IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.T_ET_Reliq_ACTUAL_1_1') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.T_ET_Reliq_ACTUAL_1_1
--Ejecutar py de Sub etiquetacion Reliquidaciones
--Ejecutar py de Sub etiquetacion Reliquidaciones
--Ejecutar py de Sub etiquetacion Reliquidaciones
--Ejecutar py de Sub etiquetacion Reliquidaciones
------------------------------------------------
--inserto todo nuevamente a Reliquid por lo que las habia borrado
INSERT INTO  CUN_REPOSITORIO.COMISIONES_CONTACT.EtiquetasReliquidacion 
SELECT * FROM CUN_REPOSITORIO.COMISIONES_CONTACT.T_ET_Reliq_ACTUAL_1_1;

--------------------------------  Paso 10. Busca en tabla Base pago mes anterior, y cruza contra las reliquidadas para sacar la diferencia ------------------------------------------------------------------------------------------------------------------------------------
IF object_id('CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BaseReliquidacionCal') IS NOT NULL
    DROP TABLE CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BaseReliquidacionCal

Select

    distinct t1.*,
              isnull(t2.Pregrados_Reliquidacion,0)Pregrados_Reliquidacion,
              isnull(t2.Postgrado_Reliquidacion,0)Postgrado_Reliquidacion,
              isnull(t2.Educacion_continuada_Reliquidacion,0)Educacion_continuada_Reliquidacion
INTO CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_BaseReliquidacionCal
    from Comisiones_Contact.BasePago t1
    left join (select distinct Documento_del_Asesor,Periodo_Pago,
       sum(case when TIPO = 'Pregrado' then 1 else 0 end) As Pregrados_Reliquidacion,
       sum(case when TIPO = 'Postgrado' then 1 else 0 end) As Postgrado_Reliquidacion,
       sum(case when TIPO = 'Educacion continuada' then 1 else 0 end) As Educacion_continuada_Reliquidacion
    from Comisiones_Contact.EtiquetasReliquidacion where EstadoFinal = 'OK'
                                                     and Periodo_Pago = '202504'
    group by Documento_del_Asesor,Periodo_Pago) t2
                                              on t1.Documento_del_Asesor = t2.Documento_del_Asesor
    where t1.Periodo_Pago = '202504'


----------------------- Paso 11. Realiza los calculos de la liquidacion del mes pasado contra reliquidacion, carga en tabla BasePagoreliquidaciones  ------------------------------------------------------------------------------------------------------------------------------------

delete from Comisiones_Contact.BasePagoReliquidaciones where Periodo_Pago = '202504'
delete from Comisiones_Contact.RELIQ_PREGR_APROB_CONTAC_MOD2 where Periodo_Pago_1 = '202504'
delete from Comisiones_Contact.RELIQ_SOL_PREG_X where Periodo_Pago_1 = '202504'
delete from Comisiones_Contact.RELIQ_DESGLO_BASE where Per_desglo = '202504'

--Ejecutar py
--Ejecutar py
--Ejecutar py
--Ejecutar py
--Ejecutar py
--Ejecutar py


--select * from Comisiones_Contact.BasePagoReliquidaciones where Periodo_Pago = '202504'

------------------------------------------------------------------ Cruce Comisiones tabla con valores ------------------------------------------------------------------------------------------------------------------------------------
 Delete from Comisiones_Contact.BasePago where Periodo_Pago = '202505'

Insert Into Comisiones_Contact.BasePago
(Documento_del_Asesor
,Periodo_Pago
,Pregrados
,Postgrado
,Educacion_continuada
,Valor_Pregrado
,Valor_Postgrado
,Valor_Educacion_continuada
,Total_Comision
,Calidad_Resultado
,Formacion_Resultado
,Ventas_Resultado
,Adherencia_Resultado
,Conversion_Resultado
,Por_Afectacion
,Deducciones
,Comisiones_Total_Deducciones
,Nombres
,email_Administrativo_he
,Reliquidacion
,Comision_Final
,Productividad_Resultado)

Select T3.Documento_del_Asesor,
T3.Periodo_Pago,
T3.Pregrados,
T3.Postgrado,
T3.Educacion_continuada,
T3.Valor_Pregrado,
T3.Valor_Postgrado,
T3.Valor_Educacion_continuada,
T3.Total_Comision,
T3.Calidad_Resultado,
T3.Formacion_Resultado,
T3.Ventas_Resultado,
T3.Adherencia_Resultado,
T3.Conversion_Resultado,
T3.Por_Afectacion,
T3.Deducciones,
t3.Total_Comision-t3.Deducciones as Comisiones_Total_Deducciones,
concat(t4.nombre_btpr,' ',t4.segundo_nombre_btpr,' ',t4.primer_apellido_btpr,' ',t4.segundo_apellido_btpr) Nombres,
t4.email_Administrativo_he,
isnull(t5.Comision_Reliquidacion,0) as Reliquidacion,
isnull((t3.Total_Comision-t3.Deducciones)+isnull(t5.Comision_Reliquidacion,0),0) as Comision_Final,
T3.Productividad_Resultado
	   
from (
select t1.*,
       isnull(t2.Calidad_Resultado,0) Calidad_Resultado,
       isnull(t2.Formacion_Resultado,0) Formacion_Resultado,
       isnull(t2.Ventas_Resultado,0) Ventas_Resultado,
       isnull(t2.Adherencia_Resultado,0) Adherencia_Resultado,
       isnull(t2.Conversion_Resultado,0) Conversion_Resultado,
       isnull(t2.Por_Afectacion,0) Por_Afectacion,
       isnull(convert(int,T1.Total_Comision*T2.Por_Afectacion),0) Deducciones,
	   isnull(t2.Productividad_Resultado,0) Productividad_Resultado
from CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_CONTEO_VENTAS t1
left join CUN_REPOSITORIO.COMISIONES_CONTACT.TEMP_AFECTACIONES t2 on t1.Documento_del_Asesor = t2.Documento_del_Asesor and t1.Periodo_Pago = t2.Periodo)t3
left join dbo.HUB_persona t4 on t3.Documento_del_Asesor = t4.identificacion_btpr
left join (select * from Comisiones_Contact.BasePagoReliquidaciones
                    where Periodo_Pago = '202505'
                    )t5 on t3.Documento_del_Asesor = t5.Documento_del_Asesor
order by (t3.Total_Comision-t3.Deducciones)+t5.Comision_Reliquidacion desc

--------- Consultas probables para envio de liquidacion ----------------------------------------------------
/*
Select distinct * from Comisiones_Contact.BasePago where Periodo_Pago = '202505'  -- PERIODO A PAGAR ACTUAL
SELECT * FROM Comisiones_Contact.Etiquetas where Periodo_Pago = '202505' AND EstadoFinal = 'OK'
SELECT * FROM Comisiones_Contact.Etiquetas where Periodo_Pago = '202505' AND EstadoFinal <> 'OK'-- BASE DE VENTAS A PAGAR
SELECT * from Comisiones_Contact.FIJA_LIQ_ACTUAL_DESGLOS where Periodo_Pago = '202505'
SELECT * from Comisiones_Contact.PREGR_APROB_CONTAC_MOD2 where Periodo_Pago_1 = '202505' 
SELECT * from Comisiones_Contact.Posg_APROB_CONTAC_MOD2 where Periodo_Pago_1 = '202505' 
*/


END