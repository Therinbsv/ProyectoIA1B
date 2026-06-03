#!/usr/bin/perl

# Pragmas para un código robusto y moderno
use strict;
use warnings;
use utf8;        # Permite usar caracteres Unicode en el código (tildes, ñ, etc.)
use Tk;          # Módulo para la interfaz gráfica (ToolKit)
use FindBin qw($Bin);

# Añadir el directorio del script al path de búsqueda de módulos
use lib $Bin;

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
my $atr_indicator = Market::Indicators::ATR->new(14);

# Registrar el indicador ATR en el gestor con el nombre 'ATR'
$indicator_manager->register('ATR', $atr_indicator);

# ============================================================================
# 2. CARGAR HISTÓRICO Y SIMULAR STREAMING PARA ATR
# ============================================================================

# Ruta del archivo CSV con los datos históricos 
my $archivo_csv = 'Data/2026_03.csv';
print "[*] Leyendo base de datos y calculando indicadores...\n";

# Abrir el archivo CSV para lectura
open my $fh, '<', $archivo_csv or die "Error: No se pudo abrir $archivo_csv: $!";

# Leer y descartar la primera línea (cabecera del CSV)
my $header = <$fh>;

# Leer el archivo línea por línea con validación de errores
my $linea_numero = 1;
while (my $linea = <$fh>) {
    $linea_numero++;
    chomp $linea;                          # Eliminar el salto de línea final
    
    # Saltar líneas vacías
    next if $linea =~ /^\s*$/;
    
    my @columnas = split /,/, $linea;      # Dividir por coma → array de 6 elementos
    
    # Validar que tenga al menos 6 columnas
    if (@columnas < 6) {
        warn "⚠️ Línea $linea_numero mal formada (solo " . scalar(@columnas) . " columnas): $linea\n";
        next;
    }
    
    # Validar que las columnas numéricas sean números válidos
    my ($ts, $open, $high, $low, $close, $vol) = @columnas;
    if ($open !~ /^-?\d+(?:\.\d+)?$/ || 
        $high !~ /^-?\d+(?:\.\d+)?$/ || 
        $low  !~ /^-?\d+(?:\.\d+)?$/ || 
        $close!~ /^-?\d+(?:\.\d+)?$/) {
        warn "⚠️ Línea $linea_numero contiene valores no numéricos: $linea\n";
        next;
    }
    
    # Añadir la vela al gestor de datos
    $market_data->add_candle(\@columnas);
}
close $fh;   

$market_data->build_timeframes();    # Crea los arrays para 5m y 15m agregando velas

# Cambiar a temporalidad de 1 minuto
$market_data->set_timeframe('1m');

# Calcular el indicador ATR para TODAS las velas (desde la primera hasta la última)
print "[*] Calculando indicador ATR para " . $market_data->size() . " velas...\n";
for (my $i = 0; $i < $market_data->size(); $i++) {
    $indicator_manager->update_last($market_data, $i);
}
print "[✓] Cálculo de indicadores completado\n";

# ============================================================================
# 3. CONSTRUCCIÓN DE LA INTERFAZ GRÁFICA
# ============================================================================

# Crear la ventana principal de la aplicación
my $mw = MainWindow->new;
$mw->title("Plataforma de Gráficos - ATR y Velas Japonesas");

# Establecer tamaño mínimo de la ventana
$mw->minsize(800, 600);

# Obtener ancho y alto de la pantalla
my $sw = eval { $mw->screenwidth }  || 1280;
my $sh = eval { $mw->screenheight } || 800;

# Validar que los valores de pantalla sean razonables 
my $screen_ok = ($sw >= 800 && $sw <= 10000 && $sh >= 600 && $sh <= 10000);

if ($screen_ok) {
    # Calcular tamaño usable restando bordes de ventana 
    my $usable_w = $sw - 16;
    my $usable_h = $sh - 96;
    
    # Asegurar un mínimo de 1280x720 para que la interfaz se vea bien
    $usable_w = 1280 if $usable_w < 1280;
    $usable_h = 720  if $usable_h < 720;
    
    # Establecer geometría: ancho x alto + offset X + offset Y (0,0 = esquina superior izquierda)
    $mw->geometry("${usable_w}x${usable_h}+0+0");
} else {
    # Si la detección de pantalla falló, usar geometría segura
    warn "[!] Tk pantalla inválida (${sw}x${sh}); usa geometría segura.\n";
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

# DIMENSIONES DE LOS EJES (en píxeles)
my $time_axis_height = 18;    # Altura del eje temporal inferior
my $right_axis_width = 60;    # Ancho del eje Y derecho (para precios)
my $atr_axis_width   = 48;    # Ancho del eje Y del ATR

# ============================================================================
# CREAR CANVAS PRIMERO (antes de los botones y del ChartEngine)
# ============================================================================

# Contenedor principal del chart (precio, eje temporal y ATR)
my $chart_frame = $mw->Frame(-background => $theme{panel_bg})->pack(-side => 'top', -expand => 1, -fill => 'both');

# Panel superior de Velas con eje de precios independiente a la derecha
my $price_frame = $chart_frame->Frame(-background => $theme{panel_bg})->pack(-side => 'top', -expand => 1, -fill => 'both');

# Canvas para el eje Y de precios 
my $price_axis_canvas = $price_frame->Canvas(
    -width             => $right_axis_width,
    -background        => $theme{panel_bg},
    -relief            => 'sunken',
    -bd                => 1,
    -cursor            => 'sb_v_double_arrow'   # Cursor de flecha vertical para arrastrar
)->pack(-side => 'right', -fill => 'y');

# Canvas principal para dibujar las velas japonesas 
my $price_canvas = $price_frame->Canvas(
    -background        => $theme{panel_bg},
    -relief            => 'sunken',
    -bd                => 1,
    -cursor            => 'crosshair'          # Cursor de cruz para el crosshair
)->pack(-side => 'left', -expand => 1, -fill => 'both');

# Eje temporal independiente, inmediatamente debajo del gráfico principal
my $time_frame = $chart_frame->Frame(-background => $theme{panel_bg})->pack(-side => 'top', -fill => 'x');

# Espaciador derecho para alinear con el eje de precios (mismo ancho)
$time_frame->Canvas(
    -width             => $right_axis_width,
    -height            => $time_axis_height,
    -background        => $theme{panel_bg},
    -relief            => 'sunken',
    -bd                => 1,
    -highlightthickness=> 0
)->pack(-side => 'right', -fill => 'y');

# Canvas principal del eje temporal (con cursor de flecha horizontal para arrastrar)
my $time_axis_canvas = $time_frame->Canvas(
    -height            => $time_axis_height,
    -background        => $theme{panel_bg},
    -relief            => 'sunken',
    -bd                => 1,
    -highlightthickness=> 0,
    -cursor            => 'sb_h_double_arrow'   # Cursor de flecha horizontal
)->pack(-side => 'left', -expand => 1, -fill => 'x');

# Panel inferior ATR debajo del eje temporal, con eje derecho alineado
my $atr_frame = $chart_frame->Frame(-background => $theme{panel_bg})->pack(-side => 'top', -fill => 'x');

# Canvas para el eje Y del ATR (lado derecho)
my $atr_axis_canvas = $atr_frame->Canvas(
    -width             => $atr_axis_width,
    -height            => 140,
    -background        => $theme{panel_bg},
    -relief            => 'sunken',
    -bd                => 1
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
    -relief            => 'sunken',
    -bd                => 1,
    -cursor            => 'crosshair'
)->pack(-side => 'left', -expand => 1, -fill => 'x');

# ============================================================================
# 4. INSTANCIAR EL MOTOR ORQUESTADOR (CHART ENGINE) - AHORA ANTES DE LOS BOTONES
# ============================================================================

# Variable para el modo de escala (auto/manual) - se enlaza con los radiobuttons
my $scale_mode = 'auto';

my $chart_engine = Market::ChartEngine->new(
    market_data       => $market_data,
    indicator_manager => $indicator_manager,
    price_canvas      => $price_canvas,
    price_axis_canvas => $price_axis_canvas,
    atr_canvas        => $atr_canvas,
    atr_axis_canvas   => $atr_axis_canvas,
    time_axis_canvas  => $time_axis_canvas,
    scale_mode_callback => sub { $scale_mode = $_[0] },
    theme             => \%theme
);

# ============================================================================
# 5. BARRA DE CONTROLES (BOTONES) - AHORA DESPUÉS DE CHART ENGINE
# ============================================================================

# Frame contenedor de los controles (botones, radios, etc.)
my $frame_controles = $mw->Frame()->pack(-side => 'bottom', -fill => 'x', -pady => 2);

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

# ========== BOTONES DE NAVEGACIÓN (INICIO / FIN) ==========
# Botón para ir al INICIO del gráfico (primera vela)
$frame_controles->Button(@button_style, -text => "⏮ Inicio", -command => sub {
    $chart_engine->go_to_start();
})->pack(-side => 'left', -padx => 2);

# Botón para ir al FIN del gráfico (última vela)
$frame_controles->Button(@button_style, -text => "⏭ Fin", -command => sub {
    $chart_engine->go_to_end();
})->pack(-side => 'left', -padx => 2);

# Separador visual
$frame_controles->Label(-text => "  |  ")->pack(-side => 'left');

# Etiqueta "Temporalidades:" antes de los botones de timeframe
$frame_controles->Label(
    -text       => "Temporalidades:",
)->pack(-side => 'left', -padx => 10);

# Botones de temporalidad (1m, 5m, 15m)
$frame_controles->Button(@button_style, -text => "1 Minuto",   -command => sub { $chart_engine->set_timeframe('1m') })->pack(-side => 'left', -padx => 2);
$frame_controles->Button(@button_style, -text => "5 Minutos",  -command => sub { $chart_engine->set_timeframe('5m') })->pack(-side => 'left', -padx => 2);
$frame_controles->Button(@button_style, -text => "15 Minutos", -command => sub { $chart_engine->set_timeframe('15m') })->pack(-side => 'left', -padx => 2);

# Etiqueta "Escala:" antes de los radiobuttons
$frame_controles->Label(
    -text       => "  Escala: ",
)->pack(-side => 'left', -padx => 6);

# Radiobutton para Modo Automático
$frame_controles->Radiobutton(
    -text       => 'Modo Automático',
    -value      => 'auto',
    -variable   => \$scale_mode,
    -command    => sub { $chart_engine->set_scale_mode('auto') },
)->pack(-side => 'left', -padx => 2);

# Radiobutton para Modo Manual
$frame_controles->Radiobutton(
    -text       => 'Modo Manual',
    -value      => 'manual',
    -variable   => \$scale_mode,
    -command    => sub { $chart_engine->set_scale_mode('manual') },
)->pack(-side => 'left', -padx => 2);

# Botón para resetear la vista (zoom=60 velas, offset=0, auto escala)
$frame_controles->Button(@button_style, -text => "Reset Vista", -command => sub { $chart_engine->reset_view() })->pack(-side => 'right', -padx => 20);

# ============================================================================
# 6. BINDINGS Y RENDER INICIAL
# ============================================================================

# Cuando la ventana principal se redimensione, pedir al motor que re-renderice
$mw->Tk::bind('<Configure>', sub { $chart_engine->request_render(); });

print "[*] Abriendo ventana y delegando control a Tk...\n";

# Actualizar la ventana para que los widgets tengan geometrías reales
$mw->update;

# Intentar maximizar la ventana (modo 'zoomed' o '-zoomed' según el sistema)
my $maximized = eval { $mw->state('zoomed'); 1 };
$maximized ||= eval { $mw->attributes('-zoomed', 1); 1 };
$mw->update if $maximized;

# Programar el render inicial con retrasos progresivos
$mw->after(300, sub {
    print "[*] Ejecutando renderizado inicial en los Canvas...\n";
    $chart_engine->render();                         # Render inmediato
    $mw->after(200, sub { $chart_engine->request_render(); });   # A los 200ms
    $mw->after(800, sub { $chart_engine->request_render(); });   # A los 800ms
    $mw->after(1500, sub { $chart_engine->request_render(); });  # A los 1500ms
});

# Iniciar el bucle principal de Tk
MainLoop;