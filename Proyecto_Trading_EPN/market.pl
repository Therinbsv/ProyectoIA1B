#!/usr/bin/perl

# Pragmas para un código robusto y moderno
use strict;      # Obliga a declarar todas las variables con 'my'
use warnings;    # Muestra advertencias para evitar errores comunes
use utf8;        # Permite usar caracteres Unicode en el código (tildes, ñ, etc.)
use Tk;          # Módulo para la interfaz gráfica (ToolKit)

# Añadir el directorio actual al path de búsqueda de módulos
# Esto permite usar 'use Market::...' con nuestros módulos locales
use lib '.';

# Importar nuestros módulos personalizados
use Market::MarketData;           # Gestor de datos OHLC y temporalidades
use Market::IndicatorManager;     # Contenedor de indicadores
use Market::Indicators::ATR;      # Implementación del indicador ATR
use Market::ChartEngine;          # Motor orquestador de gráficos

# ============================================================================
# 1. INICIALIZAR GESTOR DE DATOS E INDICADORES
# ============================================================================

# Crear el gestor de datos de mercado (almacena velas en 1m, 5m, 15m)
my $market_data = Market::MarketData->new();

# Crear el contenedor de indicadores (registrará ATR, RSI, etc.)
my $indicator_manager = Market::IndicatorManager->new();

# Crear el indicador ATR con período 14 (el más común en análisis técnico)
# Wilder original recomendaba 14 periodos para ATR
my $atr_indicator = Market::Indicators::ATR->new(14);

# Registrar el indicador ATR en el gestor con el nombre 'ATR'
# Esto permite accederlo más tarde con $indicator_manager->get('ATR')
$indicator_manager->register('ATR', $atr_indicator);

# ============================================================================
# 2. CARGAR HISTÓRICO Y SIMULAR STREAMING PARA ATR
# ============================================================================

# Ruta del archivo CSV con los datos históricos (velas de 1 minuto)
# Nota: El año 2026 es futuro, probablemente es un archivo de prueba/demo
my $archivo_csv = 'Data/2026_03.csv';
print "[*] Leyendo base de datos histórica y calculando indicadores...\n";

# Abrir el archivo CSV para lectura
open my $fh, '<', $archivo_csv or die "Error: No se pudo abrir $archivo_csv: $!";

# Leer y descartar la primera línea (cabecera del CSV)
# Normalmente la cabecera tiene: timestamp,open,high,low,close,volume
my $header = <$fh>;

# Leer el archivo línea por línea
while (my $linea = <$fh>) {
    chomp $linea;                          # Eliminar el salto de línea final
    my @columnas = split /,/, $linea;      # Dividir por coma → array de 6 elementos
    
    # Añadir la vela al gestor de datos (como arrayref)
    # La vela queda en el array de 1 minuto (datos brutos)
    $market_data->add_candle(\@columnas);
}
close $fh;    # Cerrar el archivo después de leerlo todo

$market_data->build_timeframes();    # Crea los arrays para 5m y 15m agregando velas

# Cambiar a temporalidad de 1 minuto (la más detallada para el indicador)
$market_data->set_timeframe('1m');

# Calcular el indicador ATR para TODAS las velas (desde la primera hasta la última)
# Esto es O(N) y cada update_last es O(1) gracias al algoritmo incremental de Wilder
for (my $i = 0; $i < $market_data->size(); $i++) {
    $indicator_manager->update_last($market_data, $i);
}

# ============================================================================
# 3. CONSTRUCCIÓN DE LA INTERFAZ GRÁFICA
# ============================================================================

# Crear la ventana principal de la aplicación
my $mw = MainWindow->new;
$mw->title("Plataforma de Gráficos - ATR y Velas Japonesas");

# Establecer tamaño mínimo de la ventana (no se puede reducir más de 800x600)
$mw->minsize(800, 600);

# ----------------------------------------------------------------------------
# Configurar geometría inicial de la ventana (tamaño y posición)
# Se intenta maximizar/expandir la ventana según la resolución de la pantalla
# ----------------------------------------------------------------------------

# Obtener ancho y alto de la pantalla (con valores por defecto en caso de error)
my $sw = eval { $mw->screenwidth }  || 1280;
my $sh = eval { $mw->screenheight } || 800;

# Validar que los valores de pantalla sean razonables (no valores absurdos)
my $screen_ok = ($sw >= 800 && $sw <= 10000 && $sh >= 600 && $sh <= 10000);

if ($screen_ok) {
    # Calcular tamaño usable restando bordes de ventana (16px ancho, 96px alto)
    my $usable_w = $sw - 16;
    my $usable_h = $sh - 96;
    
    # Asegurar un mínimo de 1280x720 para que la interfaz se vea bien
    $usable_w = 1280 if $usable_w < 1280;
    $usable_h = 720  if $usable_h < 720;
    
    # Establecer geometría: ancho x alto + offset X + offset Y (0,0 = esquina superior izquierda)
    $mw->geometry("${usable_w}x${usable_h}+0+0");
} else {
    # Si la detección de pantalla falló, usar geometría segura
    warn "[!] Tk reportó pantalla inválida (${sw}x${sh}); usando geometría segura.\n";
    $mw->geometry('1280x720+50+50');
}

# Asegurar que la ventana sea visible y tenga el foco
$mw->deiconify;      # Restaurar si estaba minimizada
$mw->raise;          # Traer al frente
$mw->focusForce;     # Dar foco de teclado

# ============================================================================
# PALETA DE TEMA OSCURO estilo TradingView
# ============================================================================
my %theme = (
    bg                => '#131722',    # Fondo general (gris muy oscuro)
    panel_bg          => '#181f2d',    # Fondo de paneles (azul grisáceo oscuro)
    toolbar_bg        => '#141b27',    # Fondo de la barra de herramientas
    toolbar_fg        => '#d1d6e5',    # Texto de la barra de herramientas (gris claro)
    grid              => '#2f3951',    # Color de las líneas de cuadrícula
    date_grid         => '#2f3951',    # Color de líneas de cambio de día
    axis_text         => '#c3cee8',    # Color del texto de los ejes
    bull              => '#26a69a',    # Color de velas alcistas (verde)
    bear              => '#f55a5a',    # Color de velas bajistas (rojo)
    atr_line          => '#4f8cff',    # Color de la línea del ATR (azul)
    crosshair_line    => '#7c8498',    # Color del crosshair (gris)
    label_bg          => '#222b3c',    # Fondo de etiquetas del crosshair
    label_fg          => '#f4f7ff',    # Texto de etiquetas (blanco azulado)
    last_price_bg     => '#222b3c',    # Fondo del último precio
    last_price_fg     => '#f4f7ff',    # Texto del último precio
    button_bg         => '#1d2538',    # Fondo de botones
    button_fg         => '#d1d6e5',    # Texto de botones
    button_active_bg  => '#206244',    # Fondo de botón cuando está activo/presionado
);

# Estilo común para los botones (se reutiliza con @button_style)
my @button_style = (
    -background       => $theme{button_bg},
    -foreground       => $theme{button_fg},
    -activebackground => $theme{button_active_bg},
    -activeforeground => $theme{button_fg},
    -relief           => 'flat',       # Sin relieve 3D (estilo moderno)
    -borderwidth      => 1,
    -padx             => 10,           # Padding horizontal interno
    -pady             => 4,            # Padding vertical interno
);

# ----------------------------------------------------------------------------
# DIMENSIONES DE LOS EJES (en píxeles)
# ----------------------------------------------------------------------------
my $time_axis_height = 18;    # Altura del eje temporal inferior
my $right_axis_width = 60;    # Ancho del eje Y derecho (para precios)
my $atr_axis_width   = 48;    # Ancho del eje Y del ATR

# ============================================================================
# CONSTRUCCIÓN DE LA INTERFAZ (orden correcto de widgets)
# ============================================================================

# 1. Barra superior de controles
my $toolbar = $mw->Frame(-background => $theme{toolbar_bg})->pack(-side => 'top', -fill => 'x');

# Título de la aplicación en la barra
$toolbar->Label(
    -text       => "TradingView",
    -background => $theme{toolbar_bg},
    -foreground => $theme{toolbar_fg},
    -font       => 'Helvetica 11 bold'
)->pack(-side => 'left', -padx => 14, -pady => 10);

# Frame contenedor de los controles (botones, radios, etc.)
my $frame_controles = $toolbar->Frame(-background => $theme{toolbar_bg})->pack(-side => 'left', -padx => 8);

# Etiqueta "Temporalidades:" antes de los botones de timeframe
$frame_controles->Label(
    -text       => "Temporalidades:",
    -background => $theme{toolbar_bg},
    -foreground => $theme{toolbar_fg},
    -font       => 'Helvetica 9'
)->pack(-side => 'left', -padx => 4);

# 2. Contenedor principal del chart (precio, eje temporal y ATR)
my $chart_frame = $mw->Frame(-background => $theme{panel_bg})->pack(-side => 'top', -expand => 1, -fill => 'both');

# ----------------------------------------------------------------------------
# 3. Panel superior de Velas con eje de precios independiente a la derecha
# ----------------------------------------------------------------------------
my $price_frame = $chart_frame->Frame(-background => $theme{panel_bg})->pack(-side => 'top', -expand => 1, -fill => 'both');

# Canvas para el eje Y de precios (lado derecho, ancho fijo)
my $price_axis_canvas = $price_frame->Canvas(
    -width             => $right_axis_width,
    -background        => $theme{panel_bg},
    -relief            => 'flat',
    -bd                => 0,
    -highlightthickness=> 0,          # Sin borde de focus
    -cursor            => 'sb_v_double_arrow'   # Cursor de flecha vertical para arrastrar
)->pack(-side => 'right', -fill => 'y');

# Canvas principal para dibujar las velas japonesas (se expande para llenar el espacio)
my $price_canvas = $price_frame->Canvas(
    -background        => $theme{panel_bg},
    -relief            => 'flat',
    -bd                => 0,
    -highlightthickness=> 0,
    -cursor            => 'crosshair'          # Cursor de cruz para el crosshair
)->pack(-side => 'left', -expand => 1, -fill => 'both');

# ----------------------------------------------------------------------------
# 4. Eje temporal independiente, inmediatamente debajo del gráfico principal
# ----------------------------------------------------------------------------
my $time_frame = $chart_frame->Frame(-background => $theme{panel_bg})->pack(-side => 'top', -fill => 'x');

# Espaciador derecho para alinear con el eje de precios (mismo ancho)
$time_frame->Canvas(
    -width             => $right_axis_width,
    -height            => $time_axis_height,
    -background        => $theme{panel_bg},
    -relief            => 'flat',
    -bd                => 0,
    -highlightthickness=> 0
)->pack(-side => 'right', -fill => 'y');

# Canvas principal del eje temporal (con cursor de flecha horizontal para arrastrar)
my $time_axis_canvas = $time_frame->Canvas(
    -height            => $time_axis_height,
    -background        => $theme{panel_bg},
    -relief            => 'flat',
    -bd                => 0,
    -highlightthickness=> 0,
    -cursor            => 'sb_h_double_arrow'   # Cursor de flecha horizontal
)->pack(-side => 'left', -expand => 1, -fill => 'x');

# ----------------------------------------------------------------------------
# 5. Panel inferior ATR debajo del eje temporal, con eje derecho alineado
# ----------------------------------------------------------------------------
my $atr_frame = $chart_frame->Frame(-background => $theme{panel_bg})->pack(-side => 'top', -fill => 'x');

# Canvas para el eje Y del ATR (lado derecho)
my $atr_axis_canvas = $atr_frame->Canvas(
    -width             => $atr_axis_width,
    -height            => 140,
    -background        => $theme{panel_bg},
    -relief            => 'flat',
    -bd                => 0
)->pack(-side => 'right', -fill => 'y');

# Espaciador para alinear correctamente (diferencia entre ancho de ejes)
$atr_frame->Frame(
    -width      => $right_axis_width - $atr_axis_width,
    -height     => 140,
    -background => $theme{panel_bg},
)->pack(-side => 'right', -fill => 'y');

# Canvas principal para dibujar la línea del ATR
my $atr_canvas = $atr_frame->Canvas(
    -height            => 140,
    -background        => $theme{panel_bg},
    -relief            => 'flat',
    -bd                => 0,
    -cursor            => 'crosshair'
)->pack(-side => 'left', -expand => 1, -fill => 'x');

# ============================================================================
# 4. INSTANCIAR EL MOTOR ORQUESTADOR (CHART ENGINE)
# ============================================================================
my $chart_engine = Market::ChartEngine->new(
    market_data       => $market_data,
    indicator_manager => $indicator_manager,
    price_canvas      => $price_canvas,
    price_axis_canvas => $price_axis_canvas,
    atr_canvas        => $atr_canvas,
    atr_axis_canvas   => $atr_axis_canvas,
    time_axis_canvas  => $time_axis_canvas,
    theme             => \%theme
);

# ----------------------------------------------------------------------------
# CONFIGURAR EVENTOS Y CONTROLES
# ----------------------------------------------------------------------------

# Cuando la ventana principal se redimensione, pedir al motor que re-renderice
$mw->Tk::bind('<Configure>', sub { $chart_engine->request_render(); });

# Crear los botones de temporalidad (1m, 5m, 15m) y conectarlos al motor
$frame_controles->Button(@button_style, -text => "1 Minuto",   -command => sub { $chart_engine->set_timeframe('1m') })->pack(-side => 'left', -padx => 2);
$frame_controles->Button(@button_style, -text => "5 Minutos",  -command => sub { $chart_engine->set_timeframe('5m') })->pack(-side => 'left', -padx => 2);
$frame_controles->Button(@button_style, -text => "15 Minutos", -command => sub { $chart_engine->set_timeframe('15m') })->pack(-side => 'left', -padx => 2);

# Variable para el modo de escala (auto/manual) - se enlaza con los radiobuttons
my $scale_mode = 'auto';

# Etiqueta "Escala:" antes de los radiobuttons
$frame_controles->Label(
    -text       => "  Escala: ",
    -background => $theme{toolbar_bg},
    -foreground => $theme{toolbar_fg},
    -font       => 'Helvetica 9'
)->pack(-side => 'left', -padx => 6);

# Radiobutton para escala automática (ajusta min_y/max_y automáticamente según los datos visibles)
$frame_controles->Radiobutton(
    -text       => 'Auto',
    -value      => 'auto',
    -variable   => \$scale_mode,          # Enlazado con la variable $scale_mode
    -background => $theme{toolbar_bg},
    -foreground => $theme{toolbar_fg},
    -activebackground => $theme{toolbar_bg},
    -selectcolor => $theme{toolbar_bg},
    -command    => sub { $chart_engine->set_scale_mode('auto') },
)->pack(-side => 'left', -padx => 2);

# Radiobutton para escala manual (el usuario controla min_y/max_y con arrastre del eje)
$frame_controles->Radiobutton(
    -text       => 'Manual',
    -value      => 'manual',
    -variable   => \$scale_mode,
    -background => $theme{toolbar_bg},
    -foreground => $theme{toolbar_fg},
    -activebackground => $theme{toolbar_bg},
    -selectcolor => $theme{toolbar_bg},
    -command    => sub { $chart_engine->set_scale_mode('manual') },
)->pack(-side => 'left', -padx => 2);

# Botón para resetear la vista (zoom=60 velas, offset=0, auto escala)
$frame_controles->Button(@button_style, -text => "Reset Vista", -command => sub { $chart_engine->reset_view() })->pack(-side => 'right', -padx => 20);

# ============================================================================
# 5. DISPARAR RENDER Y LOOP GRÁFICO (CON ESTABILIDAD PARA WAYLAND/WSLg)
# ============================================================================
print "[*] Abriendo ventana nativa y delegando control a Tk...\n";

# Actualizar la ventana para que los widgets tengan geometrías reales
# Esto es necesario porque los canvases necesitan saber su tamaño antes de renderizar
$mw->update;

# Intentar maximizar la ventana (modo 'zoomed' o '-zoomed' según el sistema)
my $maximized = eval { $mw->state('zoomed'); 1 };
$maximized ||= eval { $mw->attributes('-zoomed', 1); 1 };
$mw->update if $maximized;

# Programar múltiples renders con retrasos progresivos para asegurar que
# en WSLg/Wayland la ventana tenga tiempo de calcular geometrías correctas
$mw->after(300, sub {
    print "[*] Ejecutando renderizado inicial en los Canvas...\n";
    $chart_engine->render();                         # Render inmediato
    $mw->after(200, sub { $chart_engine->request_render(); });   # A los 200ms
    $mw->after(800, sub { $chart_engine->request_render(); });   # A los 800ms
    $mw->after(1500, sub { $chart_engine->request_render(); });  # A los 1500ms
});

MainLoop;