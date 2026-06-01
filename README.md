# Motor de Gráficos Financieros con Perl/Tk

## Descripción

Este proyecto implementa un motor de gráficos financieros interactivo en Perl con interfaz Tk. Permite visualizar datos de mercado en velas japonesas, calcular indicadores técnicos y ofrecer interacción en tiempo real con zoom, paneo y crosshair.

La aplicación está inspirada en el estilo de plataformas como TradingView y utiliza una arquitectura modular de cuatro capas para separar cálculo, datos, indicadores y renderizado.

## Características principales

- Visualización de velas japonesas (OHLC) a partir de datos CSV.
- Panel de indicador ATR (Average True Range).
- Temporalidades disponibles: `1m`, `5m`, `15m`.
- Interacción de usuario:
  - zoom horizontal con rueda del mouse
  - paneo con arrastre
  - crosshair sincronizado entre precio y ATR
  - etiquetas dinámicas de precio y tiempo
- Tema oscuro y diseño de interfaz inspirado en TradingView.

## Arquitectura del proyecto

El código está organizado en módulos que separan responsabilidades:

1. **Capa de datos**
   - `Market/MarketData.pm`
   - Maneja la carga, almacenamiento y agregación de datos OHLCV.
   - Construye temporalidades `1m`, `5m` y `15m` a partir de la serie base.
   - Calcula anclas temporales para el eje de tiempo.

2. **Capa de indicadores**
   - `Market/IndicatorManager.pm`
   - `Market/Indicators/ATR.pm`
   - Registra y actualiza indicadores de forma desacoplada.
   - Calcula el ATR incrementalmente sin depender del renderizado.

3. **Capa de renderizado**
   - `Market/ChartEngine.pm`
   - `Market/Panels/Scales.pm`
   - `Market/Panels/PricePanel.pm`
   - `Market/Panels/ATRPanel.pm`
   - Convierte datos financieros en coordenadas de pantalla.
   - Dibuja velas, ejes, panel ATR y objetos de interacción.
   - Gestiona eventos de usuario y actualiza la vista.

4. **Capa de presentación**
   - `market.pl`
   - Inicializa los módulos, carga datos y arranca la aplicación Tk.
   - Define el tema visual y los controles de la interfaz.

## Estructura de archivos

- `market.pl`
  - Script principal que arranca la aplicación.
  - Carga `Data/2026_03.csv` y prepara los datos.

- `Data/2026_03.csv`
  - Datos históricos de precios para el gráfico.

- `Market/MarketData.pm`
  - Gestión de datos OHLCV y generación de timeframes.
  - Proporciona slices de datos para el render.

- `Market/IndicatorManager.pm`
  - Contenedor de indicadores técnicos.
  - Actualiza los indicadores por cada vela.

- `Market/Indicators/ATR.pm`
  - Implementa el cálculo del ATR usando el método de Wilder.
  - Mantiene estado incremental y puede resetearse.

- `Market/ChartEngine.pm`
  - Orquesta el renderizado y la interacción.
  - Calcula la ventana visible, el zoom, el paneo y el crosshair.

- `Market/Panels/Scales.pm`
  - Sistema de coordenadas y etiquetado de ejes.
  - Convierte valores de precio a píxeles y dibuja grillas.

- `Market/Panels/PricePanel.pm`
  - Renderiza las velas japonesas y muestra etiquetas de precio.

- `Market/Panels/ATRPanel.pm`
  - Dibuja la línea del ATR y su etiqueta final.

## Cómo ejecutar

1. Instala Perl y la biblioteca Tk en tu sistema.
2. Abre una terminal en la carpeta del proyecto:

```bash
cd /home/ANAYOMI/Documentos/TradingProject
```

3. Ejecuta el proyecto:

```bash
perl market.pl
```

4. Si hay errores de librería, instala `Tk` en tu entorno Perl.

## Uso

- Selecciona la temporalidad con los botones `1 Minuto`, `5 Minutos` y `15 Minutos`.
- Utiliza la rueda del mouse para hacer zoom horizontal.
- Arrastra el gráfico para mover el historial de precios.
- Presiona `Reset Vista` para volver a la vista inicial.

## Mejoras visuales implementadas

- Tema oscuro inspirado en TradingView.
- Barra de controles superior con estilo moderno.
- Canvas planos y sin bordes pesados.
- Ejes separados para precio, tiempo y ATR.
- Etiquetas de precio y últimos valores en el margen derecho.

## Notas de diseño

- La capa de indicadores está separada del renderizado.
- `Market::Indicators::ATR` no depende de Tk ni de la UI.
- `Market::Panels::Scales` asegura consistencia en la conversión de datos a píxeles.
- `Market::ChartEngine` actúa como orquestador, sin mezclar lógica de cálculo con lógica de presentación.

## Futuras mejoras recomendadas

- Agregar selección de símbolo o panel lateral.
- Añadir más indicadores técnicos.
- Soporte de datos en tiempo real.
- Cambio de tema claro/oscuro desde la interfaz.
- Mejora de la barra superior con iconos y menús.
