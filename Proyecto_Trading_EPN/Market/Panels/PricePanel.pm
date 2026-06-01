package Market::Panels::PricePanel;
use strict;
use warnings;

# new(): Constructor del panel de precios (velas japonesas).
sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
    };
    # El tema (paleta clara) se inyecta vía `theme => \%theme` desde ChartEngine.
    $self->{theme} = {} unless defined $self->{theme};
    bless $self, $class;
    return $self;
}

# _init_crosshair_objects(): Inicializa los IDs de los objetos Tk del crosshair.
sub _init_crosshair_objects {
    my ($self) = @_;
    $self->{_ch_vline}    = undef;
    $self->{_ch_hline}    = undef;
    $self->{_ch_label}    = undef;
    $self->{_ch_label_bg} = undef;
}

# round(): Redondea al entero más cercano (auxiliar, aunque no se usa mucho).
sub round {
    my ($self, $value) = @_;
    return 0 unless defined $value;
    return int($value + ($value >= 0 ? 0.5 : -0.5));
}

# _canvas_size(): Obtiene ancho y alto del canvas (igual que en ATRPanel).
sub _canvas_size {
    my ($self, $canvas) = @_;
    my ($w, $h) = (0, 0);
    my $geom = eval { $canvas->geometry() };
    if (defined $geom && $geom =~ /^(\d+)x(\d+)/) {
        ($w, $h) = ($1, $2);
    }
    $w ||= eval { $canvas->Width() }  || eval { $canvas->width() }  || 1;
    $h ||= eval { $canvas->Height() } || eval { $canvas->height() } || 1;
    $w = 1 if $w < 1;
    $h = 1 if $h < 1;
    return ($w, $h);
}

# get_y_range(): Calcula el rango de precios (min, max) de las velas visibles.
# Recibe un arrayref de velas (cada una es [ts, open, high, low, close, vol]).
# Devuelve (min_price, max_price) con padding del 2%.
sub get_y_range {
    my ($self, $data) = @_;
    return (20000, 30000) if !$data || !@$data;   # Rango por defecto para BTC aprox.

    my @defined = grep { defined $_ } @$data;
    return (20000, 30000) unless @defined;

    # Inicializar min con low de la primera vela, max con high de la primera.
    my $min = $defined[0]->[3];   # low
    my $max = $defined[0]->[2];   # high

    for my $candle (@defined) {
        $min = $candle->[3] if $candle->[3] < $min;   # low más bajo
        $max = $candle->[2] if $candle->[2] > $max;   # high más alto
    }

    # Padding del 2% para que las velas no toquen los bordes.
    my $padding = ($max - $min) * 0.02 || 1;
    return ($min - $padding, $max + $padding);
}

# set_scale(): Asigna el objeto Scales a este panel.
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# render(): Dibuja todas las velas japonesas visibles sobre el canvas Tk.
sub render {
    my ($self, $canvas, $data, $scale) = @_;

    my ($canvas_w, $canvas_h) = $self->_canvas_size($canvas);
    $canvas->delete('all');   # Limpiar canvas

    return if !$data || !@$data;   # No hay datos, salir

    # ChartEngine puede inyectar un ancho compartido para sincronizar X con ATR.
    $scale->{width}  ||= $canvas_w;
    $scale->{height} = $canvas_h;

    # Guardar la última vela definida para la etiqueta de precio.
    $self->{_last_candle} = undef;
    for (my $i = $#$data; $i >= 0; $i--) {   # Recorrer de atrás hacia adelante
        if (defined $data->[$i]) {
            $self->{_last_candle} = $data->[$i];
            last;
        }
    }

    # Calcular ancho de cada barra y del cuerpo (60% del ancho de la barra).
    my $total  = scalar(@$data);
    my $x_bars = $scale->{bars} || $total || 1;
    my $bar_w  = ($x_bars > 0) ? ($scale->plot_width() / $x_bars) : 1;
    my $body_w = $bar_w * 0.6;
    $body_w = 1 if $body_w < 1;
    $body_w = $bar_w if $body_w > $bar_w;
    my $half   = $body_w / 2;   # Mitad del ancho del cuerpo para centrarlo en la coordenada X

    # Dibujar cada vela
    for (my $i = 0; $i < $total; $i++) {
        my $candle = $data->[$i];
        next unless defined $candle;

        my ($ts, $open, $high, $low, $close, $vol) = @$candle;

        # Coordenadas X (centro de la barra) y Y (para cada precio)
        my $cx  = $scale->index_to_center_x($i);
        my $y_o = $scale->value_to_y($open);
        my $y_h = $scale->value_to_y($high);
        my $y_l = $scale->value_to_y($low);
        my $y_c = $scale->value_to_y($close);

        # Color: verde (#26a69a) para vela alcista (close >= open), rojo (#ef5350) para bajista
        my $color = ($close >= $open)
            ? ($self->{theme}{bull} // '#26a69a')
            : ($self->{theme}{bear} // '#ef5350');

        # Mecha: línea delgada vertical desde high hasta low
        $canvas->createLine(
            $cx, $y_h, $cx, $y_l,
            -fill  => $color,
            -width => 1,
            -tags  => 'candle',
        );

        # Cuerpo: rectángulo entre open y close
        my $top    = ($y_o < $y_c) ? $y_o : $y_c;    # El de menor Y (más arriba en pantalla)
        my $bottom = ($y_o > $y_c) ? $y_o : $y_c;    # El de mayor Y (más abajo)
        $bottom = $top + 1 if ($bottom - $top) < 1;  # Asegurar que el rectángulo tenga al menos 1 píxel de alto

        $canvas->createRectangle(
            $cx - $half, $top,
            $cx + $half, $bottom,
            -fill    => $color,
            -outline => $color,
            -tags    => 'candle',
        );
    }

    # Inyectar colores de eje del tema en la escala antes de dibujar el eje Y.
    $scale->{grid_color}      = $self->{theme}{grid}      // '#e6e6e6';
    $scale->{axis_text_color} = $self->{theme}{axis_text} // '#363a45';

    # Dibujar el eje Y (grid y números)
    $scale->_draw_y_scale($canvas);
    $canvas->lower('y_grid');      # Enviar grid al fondo
    $canvas->raise('candle');      # Traer las velas al frente
    $self->render_last_visible_price($canvas);   # Etiqueta del último precio
}

# render_last_visible_price(): Dibuja la etiqueta con el precio de cierre de la última vela.
sub render_last_visible_price {
    my ($self, $canvas) = @_;

    $canvas->delete('price_label');
    my $scale = $self->{scale};
    return unless defined $scale && defined $self->{_last_candle};

    my ($open, $close) = @{$self->{_last_candle}}[1, 4];
    return unless defined $close;

    my $y     = $scale->value_to_y($close);
    my $w     = $scale->{width};
    my $label = sprintf("%.2f", $close);
    my $line_color = (defined $open && $close >= $open)
        ? ($self->{theme}{bull} // '#26a69a')
        : ($self->{theme}{bear} // '#ef5350');
    my $label_bg   = $line_color;
    my $label_fg   = $self->{theme}{last_price_fg} // '#ffffff';

    # Línea horizontal discontinua que cruza todo el canvas a la altura del cierre
    $canvas->createLine(
        0, $y, $w, $y,
        -fill  => $line_color,
        -dash  => [2, 3],
        -width => 1,
        -tags  => 'price_label',
    );

    # Si la escala no quiere etiqueta, salir
    return if exists $scale->{draw_last_label} && !$scale->{draw_last_label};

    # Rectángulo de fondo de la etiqueta
    $canvas->createRectangle(
        $w - 68, $y - 7, $w, $y + 7,
        -fill    => $label_bg,
        -outline => $line_color,
        -tags    => 'price_label',
    );
    # Texto de la etiqueta
    $canvas->createText(
        $w - 66, $y,
        -text   => $label,
        -anchor => 'w',
        -font   => 'Helvetica 9 bold',
        -fill   => $label_fg,
        -tags   => 'price_label',
    );
}

# draw_crosshair(): Dibuja el crosshair en este panel y sus etiquetas (valor + tiempo).
sub draw_crosshair {
    my ($self, $x, $y, $time_text) = @_;

    my $canvas = $self->{canvas};
    return unless defined $canvas;

    $canvas->delete('price_crosshair');   # Borrar crosshair anterior
    return unless defined $x;              # Si no hay X, no dibujar nada

    my ($w, $h) = $self->_canvas_size($canvas);
    my $scale = $self->{scale};

    # Colores del tema con defaults seguros (tema claro).
    my $line_color  = $self->{theme}{crosshair_line} // '#9598a1';
    my $label_bg    = $self->{theme}{label_bg}        // '#363a45';
    my $label_fg    = $self->{theme}{label_fg}        // '#ffffff';

    # Línea vertical (sincronizada con ATRPanel)
    $canvas->createLine(
        $x, 0, $x, $h,
        -fill  => $line_color,
        -dash  => [4, 4],
        -width => 1,
        -tags  => 'price_crosshair',
    );

    # Línea horizontal y etiqueta de precio bajo el cursor (si tenemos Y)
    if (defined $y) {
        $canvas->createLine(
            0, $y, $w, $y,
            -fill  => $line_color,
            -dash  => [4, 4],
            -width => 1,
            -tags  => 'price_crosshair',
        );

        if (defined $scale && (!exists $scale->{draw_crosshair_label} || $scale->{draw_crosshair_label})) {
            my $value = $scale->y_to_value($y);   # Convertir Y a precio
            my $label = sprintf("%.2f", $value);

            # Rectángulo de fondo
            $canvas->createRectangle(
                $w - 68, $y - 7, $w, $y + 7,
                -fill    => $label_bg,
                -outline => $line_color,
                -tags    => 'price_crosshair',
            );
            # Texto del precio
            $canvas->createText(
                $w - 66, $y,
                -text   => $label,
                -anchor => 'w',
                -font   => 'Helvetica 9 bold',
                -fill   => $label_fg,
                -tags   => 'price_crosshair',
            );
        }
    }

    # Etiqueta de tiempo en la banda inferior, centrada en $x (Req. 7.4).
    if (defined $time_text && length $time_text) {
        my $box_h     = 16;                 # alto de la cajita de tiempo
        my $char_w    = 6;                  # ancho aproximado por carácter
        my $pad_x     = 6;                  # padding horizontal
        my $half_w    = (length($time_text) * $char_w) / 2 + $pad_x;

        # Ajustar centro para que no se salga del canvas
        my $cx = $x;
        $cx = $half_w        if $cx - $half_w < 0;
        $cx = $w - $half_w   if $cx + $half_w > $w;

        my $top    = $h - $box_h;
        my $bottom = $h;

        $canvas->createRectangle(
            $cx - $half_w, $top, $cx + $half_w, $bottom,
            -fill    => $label_bg,
            -outline => $line_color,
            -tags    => 'price_crosshair',
        );
        $canvas->createText(
            $cx, $top + $box_h / 2,
            -text   => $time_text,
            -anchor => 'center',
            -font   => 'Helvetica 9 bold',
            -fill   => $label_fg,
            -tags   => 'price_crosshair',
        );
    }
}

# draw_time_axis(): Dibuja las etiquetas del eje de tiempo en la banda inferior.
sub draw_time_axis {
    my ($self, $canvas, $labels, $opts) = @_;

    $canvas->delete('time_axis');
    return unless $labels && @$labels;

    $opts ||= {};
    my $draw_grid   = exists $opts->{draw_grid}   ? $opts->{draw_grid}   : 1;
    my $draw_labels = exists $opts->{draw_labels} ? $opts->{draw_labels} : 1;

    my $scale = $self->{scale};
    return unless defined $scale;

    my ($w, $h) = $self->_canvas_size($canvas);
    my $label_y = int($h / 2 + 0.5);   # Centrar verticalmente en la banda inferior

    # Colores del tema claro
    my $grid_color      = $self->{theme}{grid}      // '#e6e6e6';
    my $date_grid_color = $self->{theme}{date_grid} // '#c4c9d1';
    my $text_color      = $self->{theme}{axis_text} // '#363a45';

    for my $item (@$labels) {
        my $idx     = $item->{index};
        my $text    = $item->{text};
        my $is_date = $item->{is_date} ? 1 : 0;
        next unless defined $idx && defined $text;

        # Obtener coordenada X desde la escala (centro de la barra)
        my $x = $scale->index_to_center_x($idx);

        if ($is_date) {
            # Cambio de fecha: línea más visible que el grid normal
            if ($draw_grid) {
                $canvas->createLine(
                    $x, 0, $x, $h,
                    -fill  => $date_grid_color,
                    -width => 1,
                    -tags  => ['time_axis', 'time_grid'],
                );
            }
            next unless $draw_labels;
            # Texto de fecha en negrita
            $canvas->createText(
                $x, $label_y,
                -text   => $text,
                -anchor => 'center',
                -font   => 'Helvetica 8 bold',
                -fill   => $text_color,
                -tags   => 'time_axis',
            );
        }
        else {
            # Etiqueta horaria: línea tenue y texto normal
            if ($draw_grid) {
                $canvas->createLine(
                    $x, 0, $x, $h,
                    -fill  => $grid_color,
                    -width => 1,
                    -tags  => ['time_axis', 'time_grid'],
                );
            }
            next unless $draw_labels;
            $canvas->createText(
                $x, $label_y,
                -text   => $text,
                -anchor => 'center',
                -font   => 'Helvetica 8',
                -fill   => $text_color,
                -tags   => 'time_axis',
            );
        }
    }

    # Enviar las líneas del grid al fondo
    $canvas->lower('time_grid') if $draw_grid;
}

1; 