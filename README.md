# Motor de Gráficos Financieros con Perl/Tk

**Plataforma interactiva de visualización de datos de mercado con análisis técnico en tiempo real.**

## Idea Principal

El proyecto implementa un motor de gráficos financieros profesional en Perl/Tk que replica capacidades analíticas de plataformas como TradingView. El flujo completo es:

1. **Cargar datos históricos** desde CSV con formato OHLCV (Open, High, Low, Close, Volume).
2. **Agregar múltiples temporalidades** automáticamente (1 minuto, 5 minutos, 15 minutos) a partir de datos base.
3. **Calcular indicadores técnicos** de forma desacoplada (ATR como primer indicador implementado).
4. **Renderizar gráficos interactivos** con velas japonesas, ejes sincronizados y paneles especializados.
5. **Ofrecer interacción en tiempo real** con zoom, paneo, crosshair y etiquetas dinámicas.

## Pilares Fundamentales

### 1) Arquitectura de Cuatro Capas

El código está organizado en capas independientes para máxima mantenibilidad y reutilización:

#### Capa de Datos (`Market/MarketData.pm`)

- **Carga y normalización** de archivos CSV con formato OHLCV.
- **Generación automática** de temporalidades: desde datos base (1m) genera 5m y 15m mediante agregación.
- **Cálculo de anclas temporales** para ejes (timestamps, etiquetas horarias).
- **Gestión eficiente de slices** de datos: proporciona ventanas visibles sin cargar todo en memoria.

Como se acerca a condiciones reales de uso:

- Parseado robusto de CSV con validación de campos.
- Soporte para múltiples símbolos/activos simultáneamente.
- Caché de agregaciones para evitar recálculos innecesarios.
- Interfaz agnóstica respecto a origen de datos (CSV, base de datos, API).

#### Capa de Indicadores (`Market/IndicatorManager.pm` + `Market/Indicators/ATR.pm`)

- **Registro desacoplado** de indicadores técnicos sin dependencias de UI.
- **Cálculo incremental** del ATR usando método de Wilder para series de tiempo.
- **Estado persistente** que permite reseteo sin necesidad de recalcular todo.
- **Extensibilidad** clara para agregar nuevos indicadores (RSI, MACD, Bollinger Bands, etc.).

Indicadores implementados:

- `ATR` (Average True Range): mide volatilidad en período configurable (default: 14 velas).

#### Capa de Renderizado (`Market/ChartEngine.pm` + `Market/Panels/*`)

- **Sistema de coordenadas unificado** (`Market/Panels/Scales.pm`): convierte valores financieros a píxeles.
- **Renderizado de precios** (`Market/Panels/PricePanel.pm`): dibuja velas, línea de cierre, etiquetas de valor.
- **Renderizado de indicadores** (`Market/Panels/ATRPanel.pm`): gráficos separados de indicadores.
- **Gestión centralizada** de zoom, paneo, viewport y eventos de usuario.
- **Crosshair sincronizado** que atraviesa múltiples paneles manteniendo consistencia.

#### Capa de Presentación (`market.pl`)

- **Aplicación Tk** que orquesta las capas inferiores.
- **Interfaz de usuario** con controles de temporalidad, vista y tema.
- **Gestión de eventos** del mouse y teclado.
- **Tema oscuro** inspirado en plataformas profesionales de trading.

### 2) Interacción Fluida y Profesional

- **Zoom horizontal** con rueda del mouse: amplía/reduce tiempo visible sin afectar precio.
- **Paneo con arrastre**: desplaza el historial manteniendo zoom actual.
- **Crosshair sincronizado**: líneas verticales/horizontales que cruzan precio y ATR simultáneamente.
- **Etiquetas dinámicas**: muestran precio exacto y hora en tooltips al mover el cursor.
- **Reset vista**: vuelve instantáneamente a estado inicial.
- **Temporalidades intercambiables**: cambio fluido entre 1m, 5m, 15m sin recargar datos.

### 3) Diseño Visual Inspirado en TradingView

- **Tema oscuro profesional** con colores contrastados para máxima legibilidad.
- **Canvas sin bordes pesados**: interfaz limpia y moderna.
- **Ejes separados**: precio (izquierda/derecha), tiempo (abajo), indicadores (panel inferior).
- **Grillas y escalas** proporcionales automáticas según rango visible.
- **Etiquetas finales** en margen derecho: últimos valores de precio y ATR siempre visibles.
- **Barra de controles superior**: botones de temporalidad y acciones reunidos de forma accesible.

### 4) Principios de Separación de Responsabilidades

- **Indicadores sin UI**: `Market::Indicators::ATR` es puro cálculo, reutilizable en cualquier contexto.
- **Renderizado agnóstico**: `Market::Panels::*` no conoce detalles de cálculo, solo datos de entrada/salida.
- **ChartEngine como orquestador**: gestiona flujo de datos entre capas sin mezclar lógica.
- **Extensibilidad clara**: agregar indicadores, paneles o interacciones no requiere tocar código existente.

## Arquitectura (Resumen)

```
market.pl (Presentación Tk)
    ↓
Market/ChartEngine.pm (Orquestación)
    ├─ Market/MarketData.pm (Datos OHLCV)
    ├─ Market/IndicatorManager.pm (Indicadores)
    │  └─ Market/Indicators/ATR.pm (Cálculo)
    └─ Market/Panels/
       ├─ Scales.pm (Coordenadas)
       ├─ PricePanel.pm (Renderizado de velas)
       └─ ATRPanel.pm (Renderizado de ATR)
```

**Flujo de datos:**

1. `market.pl` carga CSV mediante `MarketData::load_from_csv()`.
2. `ChartEngine` obtiene datos visibles via `MarketData::get_slice_for_view()`.
3. `IndicatorManager` recibe datos base y calcula ATR incrementalmente.
4. Paneles especializados convierten datos a coordenadas (via `Scales`) y dibujan.
5. Eventos de usuario (`zoom`, `pan`, etc.) actualizan `ChartEngine` y fuerzan redraw.

## Estructura de Directorios

```
Proyecto_Trading_EPN/
├── market.pl                      # Script principal (punto de entrada)
├── Data/
│   └── 2026_03.csv               # Dataset histórico OHLCV
└── Market/
    ├── MarketData.pm             # Capa de datos
    ├── IndicatorManager.pm       # Gestor de indicadores
    ├── ChartEngine.pm            # Orquestador de render
    ├── Indicators/
    │   └── ATR.pm                # Implementación de ATR
    └── Panels/
        ├── Scales.pm             # Sistema de coordenadas
        ├── PricePanel.pm         # Panel de precios/velas
        └── ATRPanel.pm           # Panel de indicador ATR
```

## Requisitos y Configuración

### Dependencias

- **Perl 5.20+**
- **Tk** (interfaz gráfica)

### Instalación de Dependencias

#### En sistemas Linux/macOS:

```bash
# Debian/Ubuntu
sudo apt-get install perl tk

# macOS (Homebrew)
brew install perl tk
```

#### En Windows:

Descarga **Strawberry Perl** desde [strawberryperl.com](https://strawberryperl.com) (incluye Tk).

O instala CPAN módulos:

```bash
cpan Tk
```

## Cómo Ejecutar

### Paso 1: Verificar instalación

```bash
perl -v
perl -e 'use Tk; print "Tk OK\n"'
```

### Paso 2: Ejecutar la aplicación

```bash
cd Proyecto_Trading_EPN
perl market.pl
```

### Paso 3: Solucionar problemas comunes

Si obtienes error de módulo faltante:

```bash
# Instalar Tk via CPAN
perl -MCPAN -e 'install Tk'
```

Si la ventana no aparece (servidor X en Linux remoto):

```bash
export DISPLAY=:0
perl market.pl
```

## Uso Detallado

### Controles de Temporalidad

- Presiona botón **`1 Minuto`**: cambia a vista de 1 minuto.
- Presiona botón **`5 Minutos`**: cambia a vista de 5 minutos.
- Presiona botón **`15 Minutos`**: cambia a vista de 15 minutos.

El cambio es instantáneo; los datos ya están precalculados en memoria.

### Interacción con el Gráfico

| Acción | Efecto |
|--------|--------|
| **Rueda del mouse (arriba/abajo)** | Zoom horizontal (amplía/reduce tiempo visible) |
| **Arrastrar con click izquierdo** | Paneo horizontal (desplaza el historial) |
| **Mover cursor** | Crosshair sigue posición; muestra etiquetas de precio/hora |
| **Presionar `Reset Vista`** | Vuelve a vista inicial (zoom out completo) |

### Interpretación del Gráfico

- **Panel superior**: velas japonesas con precios OHLC.
- **Panel inferior**: ATR (volatilidad). Valores altos = mercado volátil; bajos = mercado tranquilo.
- **Eje izquierdo/derecho**: escala de precios (auto-ajustada al zoom).
- **Eje inferior**: timeline con etiquetas horarias.
- **Línea vertical roja (crosshair)**: indica posición del cursor.
- **Etiquetas finales (margen derecho)**: último precio y ATR de la vela más reciente.

## Notas de Diseño

### Separación de Capas

La arquitectura permite agregar nuevas capacidades sin afectar código existente:

- **Nuevo indicador**: crea archivo en `Market/Indicators/MiIndicador.pm`, registra en `IndicatorManager.pm`.
- **Nuevo tipo de panel**: crea archivo en `Market/Panels/MiPanel.pm`, añade a `ChartEngine.pm`.
- **Nuevo origen de datos**: extiende `MarketData.pm` con método `load_from_api()` o similar.
- **Nueva interacción**: maneja en `ChartEngine.pm` sin tocar módulos de cálculo.

### Decisiones Clave de Implementación

1. **ATR incremental**: evita recalcular todo al agregar vela nueva.
2. **Caché de timeframes**: 1m → 5m y 15m se calculan una sola vez.
3. **Escalas proporcionales**: ejes se ajustan automáticamente al zoom para máxima legibilidad.
4. **Crosshair sincronizado**: un solo evento de mouse actualiza múltiples paneles simultáneamente.
5. **Canvas sin re-crear**: se redibuja en lugar de re-crear objetos (mejor performance).

### Principios Generales

- **Cálculo antes de render**: indicadores se actualizan antes de cualquier drawing.
- **Sin estado compartido**: cada módulo maneja su propio estado claramente.
- **Interfaces explícitas**: cada módulo exporta sólo lo necesario (métodos públicos claros).
- **Tests de entrada**: validación de CSV, rango de precios, timestamps válidos.

## Estructura de Datos

### Formato CSV esperado

```
timestamp,open,high,low,close,volume
2026-03-01 00:00:00,150.50,151.00,150.25,150.80,1000
2026-03-01 00:01:00,150.80,151.20,150.70,150.95,1200
...
```

Campos:
- `timestamp`: fecha/hora en formato ISO 8601 (YYYY-MM-DD HH:MM:SS)
- `open`, `high`, `low`, `close`: precios en valores reales
- `volume`: cantidad transaccionada

### Estructura de Vela (Candle)

```perl
{
    timestamp => '2026-03-01 00:00:00',
    open      => 150.50,
    high      => 151.00,
    low       => 150.25,
    close     => 150.80,
    volume    => 1000
}
```

## Futuras Mejoras Recomendadas

### Corto Plazo

- [ ] Agregar más indicadores técnicos (RSI, MACD, Bollinger Bands).
- [ ] Soporte para selección múltiple de símbolos/activos.
- [ ] Persitencia de zoom/paneo (guardar estado entre sesiones).
- [ ] Exportación de gráficos a PNG/PDF.

### Mediano Plazo

- [ ] Datos en tiempo real (conexión WebSocket a feed de mercado).
- [ ] Panel lateral con selección de símbolo y timeframe avanzada.
- [ ] Tema claro/oscuro intercambiable desde interfaz.
- [ ] Herramientas de drawing (líneas de soporte/resistencia).
- [ ] Alertas de precio configurables.

### Largo Plazo

- [ ] Gestor de portafolio integrado.
- [ ] Backtesting de estrategias.
- [ ] API REST para integración con servicios externos.
- [ ] Soporte para múltiples frames simultáneamente.
- [ ] Análisis de volumen avanzado (profile, footprint).


