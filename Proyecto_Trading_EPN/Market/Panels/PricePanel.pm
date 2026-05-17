package Market::Panels::PricePanel;
# Renderiza el grafico principal de precios (velas japonesas OHLC).
# Maneja escalado vertical, dibujo de velas, eje de tiempo y crosshair.
# Responsabilidad unica: SOLO renderizado, SIN logica de datos.
use strict;
use warnings;
use List::Util qw(min max);

sub new {
    my ($class, %args) = @_;
    my $self = {
        up_color    => $args{up_color}    // '#26a69a',   # verde TradingView
        down_color  => $args{down_color}  // '#ef5350',   # rojo TradingView
        wick_color  => $args{wick_color}  // '#888888',
        bg_color    => $args{bg_color}    // '#ffffff',
        canvas      => undef,
        scale       => undef,
        data        => [],
        # IDs de los items del crosshair en el canvas
        _ch_v       => undef,   # linea vertical
        _ch_h       => undef,   # linea horizontal
        _ch_price   => undef,   # etiqueta de precio en eje Y
        _ch_time    => undef,   # etiqueta de tiempo en eje X
        _ch_box     => undef,   # fondo de etiqueta de precio
        _ch_timebox => undef,   # fondo de etiqueta de tiempo
    };
    bless $self, $class;
    return $self;
}

# Crea los objetos graficos del crosshair (se llama una vez al inicializar).
# Input: $canvas (Tk::Canvas)
sub _init_crosshair_objects {
    my ($self, $canvas) = @_;
    $self->{canvas} = $canvas;
    $canvas->delete('crosshair');
    # Linea vertical
    $self->{_ch_v} = $canvas->createLine(0,0,0,0,
        -fill => '#999999', -dash => [3,3], -tags => 'crosshair', -state => 'hidden');
    # Linea horizontal
    $self->{_ch_h} = $canvas->createLine(0,0,0,0,
        -fill => '#999999', -dash => [3,3], -tags => 'crosshair', -state => 'hidden');
    # Caja del precio en eje Y (fondo negro como TradingView)
    $self->{_ch_box} = $canvas->createRectangle(0,0,0,0,
        -fill => '#131722', -outline => '#131722', -tags => 'crosshair', -state => 'hidden');
    # Texto del precio en eje Y
    $self->{_ch_price} = $canvas->createText(0,0,
        -text => '', -fill => '#ffffff', -font => ['Helvetica', 9, 'bold'],
        -anchor => 'e', -tags => 'crosshair', -state => 'hidden');
    # Caja del tiempo en eje X (fondo negro)
    $self->{_ch_timebox} = $canvas->createRectangle(0,0,0,0,
        -fill => '#131722', -outline => '#131722', -tags => 'crosshair', -state => 'hidden');
    # Texto del tiempo en eje X
    $self->{_ch_time} = $canvas->createText(0,0,
        -text => '', -fill => '#ffffff', -font => ['Helvetica', 9],
        -anchor => 'n', -tags => 'crosshair', -state => 'hidden');
}

# Redondeo auxiliar.
sub round {
    my ($self, $value) = @_;
    return int($value + 0.5);
}

# Renderiza todas las velas visibles en el canvas.
# Input: $canvas (Tk::Canvas), $data (arrayref de velas), $scale (Scales)
sub render {
    my ($self, $canvas, $data, $scale) = @_;
    $canvas->delete('price_candles');
    return unless $data && @$data;

    $self->{scale}  = $scale;
    $self->{data}   = $data;
    $self->{canvas} = $canvas;

    my $bar_w    = $scale->{width} / $scale->{visible_bars};
    my $body_pad = ($bar_w > 4) ? 1 : 0;

    for my $i (0 .. $#$data) {
        my $c   = $data->[$i];
        my $idx = $scale->{offset} + $i;

        my $x_center = $scale->index_to_center_x($idx);
        my $x_left   = $scale->index_to_x($idx)     + $body_pad;
        my $x_right  = $scale->index_to_x($idx + 1) - $body_pad;

        # Minimo 1px de ancho para velas muy pequeñas
        if ($x_right - $x_left < 1) {
            $x_left  = $x_center - 0.5;
            $x_right = $x_center + 0.5;
        }

        my $y_high  = $scale->value_to_y($c->{high});
        my $y_low   = $scale->value_to_y($c->{low});
        my $y_open  = $scale->value_to_y($c->{open});
        my $y_close = $scale->value_to_y($c->{close});

        my $is_bull = ($c->{close} >= $c->{open});
        my $color   = $is_bull ? $self->{up_color} : $self->{down_color};

        my $y_top = $is_bull ? $y_close : $y_open;
        my $y_bot = $is_bull ? $y_open  : $y_close;
        $y_bot += 1 if $y_top == $y_bot;   # vela doji: al menos 1px

        # Mecha (wick)
        $canvas->createLine($x_center, $y_high, $x_center, $y_low,
            -fill => $color, -width => 1, -tags => 'price_candles');

        # Cuerpo de la vela
        $canvas->createRectangle($x_left, $y_top, $x_right, $y_bot,
            -fill => $color, -outline => $color, -tags => 'price_candles');
    }
}

# Dibuja la etiqueta del ultimo precio visible en el eje Y (caja como TradingView).
# Input: $canvas (Tk::Canvas)
sub render_last_visible_price {
    my ($self, $canvas) = @_;
    $canvas->delete('last_price');
    return unless $self->{scale} && $self->{data} && @{ $self->{data} };

    my $last  = $self->{data}[-1];
    my $close = $last->{close};
    my $y     = $self->{scale}->value_to_y($close);
    my $w     = $self->{scale}->{width};
    my $label = sprintf("%.2f", $close);

    # Caja de fondo azul TradingView
    $canvas->createRectangle($w - 63, $y - 8, $w, $y + 8,
        -fill => '#2962ff', -outline => '#2962ff', -tags => 'last_price');
    $canvas->createText($w - 4, $y,
        -text => $label, -anchor => 'e',
        -fill => '#ffffff', -font => ['Helvetica', 9, 'bold'],
        -tags => 'last_price');
}

# Calcula el rango min/max de precios visibles con padding del 5%.
# Input: $data (arrayref de velas)
# Output: ($min_val, $max_val)
sub get_y_range {
    my ($self, $data) = @_;
    return (0, 1) unless $data && @$data;
    my $mn = min(map { $_->{low}  } @$data);
    my $mx = max(map { $_->{high} } @$data);
    my $pad = ($mx - $mn) * 0.05;
    $pad = 0.5 if $pad < 0.5;
    return ($mn - $pad, $mx + $pad);
}

# Asigna la escala de valores a pixeles.
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# Dibuja el crosshair (lineas + etiquetas) en este panel.
# Input: $x, $y (coordenadas del mouse), $timestamp (string ISO)
sub draw_crosshair {
    my ($self, $x, $y, $timestamp) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas && defined $self->{_ch_v};

    my $scale = $self->{scale};
    return unless $scale;

    my $w = $scale->{width};
    my $h = $scale->{height};

    # Linea vertical
    $canvas->coords($self->{_ch_v}, $x, 0, $x, $h);
    $canvas->itemconfigure($self->{_ch_v}, -state => 'normal');

    # Linea horizontal
    $canvas->coords($self->{_ch_h}, 0, $y, $w, $y);
    $canvas->itemconfigure($self->{_ch_h}, -state => 'normal');

    # Precio en eje Y con caja negra
    my $price_val = $scale->y_to_value($y);
    my $price_lbl = sprintf("%.2f", $price_val);
    $canvas->coords($self->{_ch_box}, $w - 65, $y - 9, $w, $y + 9);
    $canvas->itemconfigure($self->{_ch_box}, -state => 'normal');
    $canvas->coords($self->{_ch_price}, $w - 4, $y);
    $canvas->itemconfigure($self->{_ch_price}, -state => 'normal', -text => $price_lbl);

    # Tiempo en eje X con caja negra
    if (defined $timestamp) {
        my $time_lbl = _format_time_label($timestamp);
        my $lbl_half = 38;
        $canvas->coords($self->{_ch_timebox}, $x - $lbl_half, $h - 18, $x + $lbl_half, $h - 2);
        $canvas->itemconfigure($self->{_ch_timebox}, -state => 'normal');
        $canvas->coords($self->{_ch_time}, $x, $h - 10);
        $canvas->itemconfigure($self->{_ch_time}, -state => 'normal', -text => $time_lbl);
    }

    # Asegurarse que el crosshair este sobre las velas
    $canvas->raise('crosshair');
}

# Oculta el crosshair.
sub hide_crosshair {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    $canvas->itemconfigure('crosshair', -state => 'hidden');
}

# Dibuja el eje horizontal de tiempo con etiquetas y lineas verticales.
# Input: $canvas, $anchors (arrayref de {index, label}),
#        $offset, $visible_bars, $scale
sub draw_time_axis {
    my ($self, $canvas, $anchors, $offset, $visible_bars, $scale) = @_;
    $canvas->delete('time_axis');
    return unless $anchors && @$anchors && $scale;

    my $h      = $scale->{height};
    my $w      = $scale->{width};
    my $y_line = $h - 20;   # Y donde van las etiquetas
    my $last_x = -999;
    my $min_sep = 65;       # separacion minima entre etiquetas (px)

    for my $t (@$anchors) {
        my $idx = $t->{index};
        # Solo mostrar si esta en la ventana visible
        next unless $idx >= $offset && $idx < $offset + $visible_bars;

        my $x = $scale->index_to_center_x($idx);
        next if $x < 0 || $x > $w - 65;
        next if ($x - $last_x) < $min_sep;
        $last_x = $x;

        # Linea vertical de grilla punteada
        $canvas->createLine($x, 0, $x, $h - 22,
            -fill => '#e0e0e0', -dash => [4, 4], -tags => 'time_axis');

        # Etiqueta de tiempo
        $canvas->createText($x, $y_line + 2,
            -text   => $t->{label},
            -anchor => 'n',
            -fill   => '#555555',
            -font   => ['Helvetica', 8],
            -tags   => 'time_axis');
    }
}

# Helper: formatea un timestamp ISO para mostrar en el crosshair del eje X.
# Input: string ISO8601 ej: '2026-04-01T09:35:00-05:00'
# Output: string formateado ej: '01 Apr 09:35'
sub _format_time_label {
    my ($ts) = @_;
    return '' unless defined $ts;
    # Extraer componentes del timestamp
    if ($ts =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/) {
        my ($yyyy, $mm, $dd, $hh, $mi) = ($1, $2, $3, $4, $5);
        my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
        my $mon = $months[$mm - 1] // '';
        return "$dd $mon $hh:$mi";
    }
    return $ts;
}

1;