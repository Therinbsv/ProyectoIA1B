#!/usr/bin/env perl
# market.pl - Punto de entrada del sistema de charting financiero.
# Controla el ciclo principal de ejecucion y actualizacion de datos.
# Replica funcionalidades de TradingView usando Tk.
use strict;
use warnings;

# Ajustar la ruta de librerias al directorio del proyecto
use lib '.';

use Tk;
use Time::Moment;
use Market::MarketData;
use Market::Indicators::ATR;
use Market::IndicatorManager;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;
use Market::ChartEngine;

# ---------------------------------------------------------------
# 1. Cargar datos del CSV
# ---------------------------------------------------------------
my $csv_file = '2026_03.csv';
die "No se encuentra $csv_file\n" unless -f $csv_file;

my $market = Market::MarketData->new();

open(my $fh, '<', $csv_file) or die "No se puede abrir $csv_file: $!\n";
my $header = <$fh>;   # saltar encabezado

while (my $line = <$fh>) {
    chomp $line;
    next if $line =~ /^\s*$/;
    my @f = split /,/, $line;
    next unless @f >= 6;
    my ($time, $open, $high, $low, $close, $vol) = @f;
    # Limpiar espacios
    s/^\s+|\s+$//g for ($time, $open, $high, $low, $close, $vol);
    $market->add_candle({
        time   => $time,
        open   => $open  + 0,
        high   => $high  + 0,
        low    => $low   + 0,
        close  => $close + 0,
        volume => $vol   + 0,
    });
}
close($fh);

# Construir timeframes 5m y 15m a partir de 1m
$market->build_timeframes();

# ---------------------------------------------------------------
# 2. Indicador ATR y gestor de indicadores
# ---------------------------------------------------------------
my $atr     = Market::Indicators::ATR->new(14);
my $ind_mgr = Market::IndicatorManager->new();
$ind_mgr->register('ATR', $atr);

# Calcular ATR para todas las velas del timeframe inicial (1m)
my $total_candles = $market->size();
for my $i (0 .. $total_candles - 1) {
    $atr->update_last($market, $i);
}

# ---------------------------------------------------------------
# 3. Interfaz grafica Tk
# ---------------------------------------------------------------
my $mw = MainWindow->new();
$mw->title("Chart Test - EPN");
$mw->geometry("1200x750");
$mw->configure(-bg => '#ffffff');
$mw->resizable(1, 1);

# --- Barra superior: botones Zoom y Timeframe + info OHLCV ---
my $top_bar = $mw->Frame(-bg => '#f5f5f5', -relief => 'flat', -bd => 0)
    ->pack(-side => 'top', -fill => 'x');

# Boton Zoom (Menu desplegable)
my $zoom_menu = $top_bar->Menubutton(
    -text        => 'Zoom',
    -bg          => '#e8e8e8',
    -fg          => '#333333',
    -activebackground => '#d0d0d0',
    -relief      => 'flat',
    -font        => ['Helvetica', 10],
    -padx        => 8,
    -pady        => 4,
    -indicatoron => 0,
)->pack(-side => 'left', -padx => 4, -pady => 2);

# Etiqueta del timeframe activo
my $tf_label_var = '1m';
my $tf_btn = $top_bar->Menubutton(
    -text        => '1m',
    -bg          => '#e8e8e8',
    -fg          => '#333333',
    -activebackground => '#d0d0d0',
    -relief      => 'flat',
    -font        => ['Helvetica', 10, 'bold'],
    -padx        => 8,
    -pady        => 4,
    -indicatoron => 0,
)->pack(-side => 'left', -padx => 2, -pady => 2);

# Etiqueta de informacion OHLCV (esquina superior izquierda)
my $info_label = $top_bar->Label(
    -text       => '',
    -bg         => '#f5f5f5',
    -fg         => '#555555',
    -font       => ['Helvetica', 9],
    -anchor     => 'w',
)->pack(-side => 'left', -padx => 12);

# --- Canvas del panel de precios ---
my $price_canvas = $mw->Canvas(
    -bg                 => '#ffffff',
    -highlightthickness => 0,
    -cursor             => 'crosshair',
)->pack(-side => 'top', -fill => 'both', -expand => 1);

# --- Separador ---
$mw->Frame(-height => 3, -bg => '#cccccc')->pack(-side => 'top', -fill => 'x');

# --- Canvas del panel ATR ---
my $atr_canvas = $mw->Canvas(
    -bg                 => '#ffffff',
    -highlightthickness => 0,
    -cursor             => 'crosshair',
    -height => 200,
)->pack(-side => "top", -fill => "both", -expand => 0);

# Esperar a que Tk asigne dimensiones reales
$mw->update();
my $width    = $price_canvas->width()  || 1160;
my $h_price  = $price_canvas->height() || 520;
my $h_atr = $atr_canvas->height() || 200;

# ---------------------------------------------------------------
# 4. Paneles de renderizado
# ---------------------------------------------------------------
my $price_panel = Market::Panels::PricePanel->new(
    up_color   => '#26a69a',   # verde TradingView
    down_color => '#ef5350',   # rojo TradingView
    wick_color => '#888888',
);

my $atr_panel = Market::Panels::ATRPanel->new(
    line_color => '#c0392b',
    line_width => 1,
);

# ---------------------------------------------------------------
# 5. Motor del grafico (ChartEngine)
# ---------------------------------------------------------------
# Mostrar las ultimas 100 velas al iniciar
my $initial_bars   = ($total_candles < 100) ? $total_candles : 100;
my $initial_offset = $total_candles - $initial_bars;
$initial_offset    = 0 if $initial_offset < 0;

my $engine = Market::ChartEngine->new(
    market_data   => $market,
    indicator_mgr => $ind_mgr,
    price_panel   => $price_panel,
    atr_panel     => $atr_panel,
    price_canvas  => $price_canvas,
    atr_canvas    => $atr_canvas,
    info_label    => $info_label,
    width         => $width,
    height_price  => $h_price,
    height_atr    => $h_atr,
    visible_bars  => $initial_bars,
    offset        => $initial_offset,
);

# ---------------------------------------------------------------
# 6. Menus de Zoom y Timeframe
# ---------------------------------------------------------------

# Opciones de zoom: cantidad de velas visibles
$zoom_menu->command(-label => 'Acercar (30 velas)',
    -command => sub {
        my $t = $market->size();
        my $v = 30 < $t ? 30 : $t;
        $engine->{visible_bars} = $v;
        my $max_off = $t - $v;
        $engine->{offset} = $max_off if $engine->{offset} > $max_off;
        $engine->request_render();
    });
$zoom_menu->command(-label => 'Normal (100 velas)',
    -command => sub {
        my $t = $market->size();
        my $v = 100 < $t ? 100 : $t;
        $engine->{visible_bars} = $v;
        my $off = $t - $v;
        $engine->{offset} = $off < 0 ? 0 : $off;
        $engine->request_render();
    });
$zoom_menu->command(-label => 'Alejar (200 velas)',
    -command => sub {
        my $t = $market->size();
        my $v = 200 < $t ? 200 : $t;
        $engine->{visible_bars} = $v;
        my $off = $t - $v;
        $engine->{offset} = $off < 0 ? 0 : $off;
        $engine->request_render();
    });
$zoom_menu->command(-label => 'Todo',
    -command => sub {
        my $t = $market->size();
        $engine->{visible_bars} = $t;
        $engine->{offset} = 0;
        $engine->request_render();
    });

# Opciones de temporalidad (maximo 5m segun especificacion)
$tf_btn->command(-label => '1 min',
    -command => sub {
        $engine->set_timeframe('1m');
        $tf_btn->configure(-text => '1m');
        # Recalcular ATR para 1m
    });
$tf_btn->command(-label => '5 min',
    -command => sub {
        $engine->set_timeframe('5m');
        $tf_btn->configure(-text => '5m');
    });

# ---------------------------------------------------------------
# 7. Resize del canvas: re-renderizar cuando cambia el tamaño
# ---------------------------------------------------------------
$price_canvas->bind('<Configure>' => sub {
    $engine->request_render();
});
$atr_canvas->bind('<Configure>' => sub {
    $engine->request_render();
});

# ---------------------------------------------------------------
# 8. Primer render
# ---------------------------------------------------------------
$engine->request_render();

# ---------------------------------------------------------------
# 9. Loop principal de Tk
# ---------------------------------------------------------------
MainLoop();