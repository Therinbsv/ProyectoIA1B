package Market::ChartEngine;
# Motor principal del grafico. Orquesta el renderizado completo del sistema.
# Coordina paneles, escalas y eventos del usuario.
# Es el punto de ensamblaje: recibe referencias a market, indicators,
# canvases y widgets Tk. Define estado interno: zoom, offset, crosshair.
# NO mezcla logica de calculo con renderizado.
use strict;
use warnings;
use lib '/home/kathe/Documentos/Proyecto_Trading_EPN';
use Market::Panels::Scales;
use List::Util qw(min max);

sub new {
    my ($class, %args) = @_;
    my $self = {
        market_data   => $args{market_data},
        indicator_mgr => $args{indicator_mgr},
        price_panel   => $args{price_panel},
        atr_panel     => $args{atr_panel},
        price_canvas  => $args{price_canvas},
        atr_canvas    => $args{atr_canvas},
        info_label    => $args{info_label},
        width         => $args{width}        // 800,
        height_price  => $args{height_price} // 420,
        height_atr    => $args{height_atr}   // 200,
        visible_bars  => $args{visible_bars} // 100,
        offset        => $args{offset}       // 0,
        # Estado de arrastre: compartido entre ambos canvas
        _drag_start_x      => undef,
        _drag_start_offset => undef,
        # Flag de render diferido
        _render_pending    => 0,
        # Ultimo indice bajo el cursor
        _cursor_index      => undef,
    };
    bless $self, $class;

    # Pasar referencia del canvas a los paneles
    $self->{price_panel}->{canvas} = $self->{price_canvas};
    $self->{atr_panel}->{canvas}   = $self->{atr_canvas};

    # Inicializar crosshairs
    $self->{price_panel}->_init_crosshair_objects($self->{price_canvas});
    $self->{atr_panel}->_init_crosshair($self->{atr_canvas});

    # Registrar eventos (AMBOS canvas comparten el mismo estado)
    $self->bind_events();

    return $self;
}

# Calcula que porcion de datos es visible segun offset y visible_bars.
# Garantiza que el offset no se salga de rango.
# Output: ($candles_arrayref, $atr_slice_arrayref)
sub compute_window {
    my ($self) = @_;
    my $total = $self->{market_data}->size();
    return ([], []) unless $total > 0;

    my $bars   = $self->{visible_bars};
    my $offset = $self->{offset};

    # Clamping del offset
    my $max_offset = $total - $bars;
    $max_offset = 0 if $max_offset < 0;
    $offset = 0           if $offset < 0;
    $offset = $max_offset if $offset > $max_offset;
    $self->{offset} = $offset;

    my $end = $offset + $bars - 1;
    $end = $total - 1 if $end >= $total;

    my @candles;
    for my $i ($offset .. $end) {
        push @candles, $self->{market_data}->get_candle($i);
    }

    # Obtener slice del ATR directamente desde el indicador
    my $atr_ind = $self->{indicator_mgr}->get('ATR');
    my $atr_all = $atr_ind ? $atr_ind->get_values() : [];
    my @atr_slice;
    if ($atr_all && @$atr_all) {
        my $atr_end = $end < $#$atr_all ? $end : $#$atr_all;
        if ($offset <= $atr_end) {
            @atr_slice = @{$atr_all}[$offset .. $atr_end];
        }
    }

    return (\@candles, \@atr_slice);
}

# Redondeo numerico auxiliar.
sub round {
    my ($self, $value) = @_;
    return int($value + 0.5);
}

# Solicita un render diferido.
# Usa el MainWindow para el after() para que funcione desde cualquier canvas.
sub request_render {
    my ($self) = @_;
    return if $self->{_render_pending};
    $self->{_render_pending} = 1;
    # Usar price_canvas para el after — es el widget raiz del sistema
    $self->{price_canvas}->after(1, sub {
        $self->{_render_pending} = 0;
        $self->render();
    });
}

# Renderiza TODO el grafico de una vez: ambos paneles con el mismo offset.
# Este metodo es el unico que dibuja — garantiza sincronizacion perfecta.
sub render {
    my ($self) = @_;

    # Obtener dimensiones actuales de cada canvas
    my $w       = $self->{price_canvas}->width()  || $self->{width};
    my $h_price = $self->{price_canvas}->height() || $self->{height_price};
    my $h_atr   = $self->{atr_canvas}->height()   || $self->{height_atr};
    $self->{width}        = $w;
    $self->{height_price} = $h_price;
    $self->{height_atr}   = $h_atr;

    # Calcular ventana visible (mismo offset para ambos paneles)
    my ($candles, $atr_slice) = $self->compute_window();
    return unless @$candles;

    # ---- Panel de precios ----
    my ($p_min, $p_max) = $self->{price_panel}->get_y_range($candles);
    my $price_scale = Market::Panels::Scales->new(
        min_val      => $p_min,
        max_val      => $p_max,
        width        => $w,
        height       => $h_price,
        visible_bars => $self->{visible_bars},
        offset       => $self->{offset},
        padding      => 20,
    );
    $self->{price_panel}->render($self->{price_canvas}, $candles, $price_scale);
    $price_scale->_draw_y_scale($self->{price_canvas});

    # Eje de tiempo en panel de precios
    my $anchors = $self->{market_data}->compute_time_anchors();
    $self->{price_panel}->draw_time_axis(
        $self->{price_canvas}, $anchors,
        $self->{offset}, $self->{visible_bars}, $price_scale
    );
    $self->{price_panel}->render_last_visible_price($self->{price_canvas});

    # ---- Panel ATR ----
    my ($a_min, $a_max) = $self->{atr_panel}->get_y_range($atr_slice);
    my $atr_scale = Market::Panels::Scales->new(
        min_val      => $a_min,
        max_val      => $a_max,
        width        => $w,
        height       => $h_atr,
        visible_bars => $self->{visible_bars},
        offset       => $self->{offset},   # MISMO offset que el panel de precios
        padding      => 15,
    );
    $self->{atr_panel}->render($self->{atr_canvas}, $atr_slice, $atr_scale);
    $atr_scale->_draw_y_scale($self->{atr_canvas});
    $self->{atr_panel}->render_last_visible_value($self->{atr_canvas});

    # Eje de tiempo en panel ATR (sincronizado con panel de precios)
    $self->{price_panel}->draw_time_axis(
        $self->{atr_canvas}, $anchors,
        $self->{offset}, $self->{visible_bars}, $atr_scale
    );

    # Guardar escalas para crosshair
    $self->{_price_scale} = $price_scale;
    $self->{_atr_scale}   = $atr_scale;
    $self->{_candles}     = $candles;
    $self->{_atr_slice}   = $atr_slice;
}

# Asocia TODOS los eventos de interaccion a los dos canvas.
# Los dos canvas comparten el mismo estado de offset/zoom del engine,
# por eso cualquier arrastre o zoom en cualquiera de los dos afecta a ambos.
sub _bind_all_canvas {
    my ($self, @canvases) = @_;
    for my $c (@canvases) {

        # --- Inicio de arrastre ---
        $c->bind('<Button-1>' => sub {
            $self->{_drag_start_x}      = $c->XEvent->x;
            $self->{_drag_start_offset} = $self->{offset};
        });

        # --- Scroll horizontal arrastrando (mueve AMBOS paneles) ---
        $c->bind('<B1-Motion>' => sub {
            return unless defined $self->{_drag_start_x};
            my $dx      = $c->XEvent->x - $self->{_drag_start_x};
            my $bar_w   = $self->{width} / $self->{visible_bars};
            my $shift   = int($dx / $bar_w);
            my $new_off = $self->{_drag_start_offset} - $shift;
            my $total   = $self->{market_data}->size();
            my $max_off = $total - $self->{visible_bars};
            $max_off = 0 if $max_off < 0;
            $new_off = 0        if $new_off < 0;
            $new_off = $max_off if $new_off > $max_off;
            # Actualizar el UNICO offset compartido
            $self->{offset} = $new_off;
            # Un solo render para ambos paneles
            $self->request_render();
        });

        # --- Fin de arrastre ---
        $c->bind('<ButtonRelease-1>' => sub {
            $self->{_drag_start_x} = undef;
        });

        # --- Zoom horizontal con rueda (Linux Button-4/5) ---
        $c->bind('<Button-4>' => sub { $self->_horizontal_zoom(-5); });
        $c->bind('<Button-5>' => sub { $self->_horizontal_zoom( 5); });

        # --- Zoom horizontal con rueda (Windows/Mac MouseWheel) ---
        $c->bind('<MouseWheel>' => sub {
            my $delta = $c->XEvent->D // 0;
            $self->_horizontal_zoom($delta > 0 ? -5 : 5);
        });

        # --- Movimiento del mouse → crosshair sincronizado ---
        $c->bind('<Motion>' => sub {
            my $x = $c->XEvent->x;
            my $y = $c->XEvent->y;
            $self->_on_mouse_move($c, $x, $y);
        });

        # --- Mouse sale del canvas → ocultar crosshair en ambos ---
        $c->bind('<Leave>' => sub {
            $self->{price_panel}->hide_crosshair();
            $self->{atr_panel}->hide_crosshair();
            $self->{info_label}->configure(-text => '') if $self->{info_label};
        });
    }
}

# Registra eventos en ambos canvas.
sub bind_events {
    my ($self) = @_;
    $self->_bind_all_canvas($self->{price_canvas}, $self->{atr_canvas});
}

# Controla zoom horizontal: modifica visible_bars y re-renderiza AMBOS paneles.
# Input: $delta > 0 = mas velas (alejar), $delta < 0 = menos velas (acercar)
sub _horizontal_zoom {
    my ($self, $delta) = @_;
    my $total   = $self->{market_data}->size();
    my $new_vis = $self->{visible_bars} + $delta;
    $new_vis = 10     if $new_vis < 10;
    $new_vis = $total if $new_vis > $total;

    # Mantener el centro de la vista al hacer zoom
    my $center = $self->{offset} + $self->{visible_bars} / 2;
    $self->{visible_bars} = $new_vis;
    $self->{offset} = int($center - $new_vis / 2);

    my $max_off = $total - $new_vis;
    $max_off = 0 if $max_off < 0;
    $self->{offset} = 0        if $self->{offset} < 0;
    $self->{offset} = $max_off if $self->{offset} > $max_off;

    # Un solo render sincroniza ambos paneles
    $self->request_render();
}

# Controla desplazamiento vertical manual (reservado para implementacion futura).
sub _vertical_drag {
    my ($self, $dy) = @_;
    # TODO: ajustar rango Y cuando no esta en modo automatico
}

# Controla zoom vertical (reservado para implementacion futura).
sub _vertical_zoom {
    my ($self, $factor) = @_;
    # TODO: escalar el eje de precios verticalmente
}

# Maneja el movimiento del mouse: actualiza crosshair e info OHLCV.
# Detecta en que canvas esta el mouse y propaga el crosshair al otro.
# Input: $source_canvas, $x, $y (coordenadas en ese canvas)
sub _on_mouse_move {
    my ($self, $source_canvas, $x, $y) = @_;

    my $scale = $self->{_price_scale};
    return unless $scale;

    # Obtener indice de la vela bajo el cursor (en coordenadas compartidas X)
    my $idx   = int($scale->x_to_index_float($x));
    my $total = $self->{market_data}->size();
    $idx = 0         if $idx < 0;
    $idx = $total -1 if $idx >= $total;
    $self->{_cursor_index} = $idx;

    # Timestamp de la vela bajo el cursor
    my $timestamp = $self->{market_data}->get_timestamp($idx);

    # Calcular Y del crosshair en el panel ATR (posicion proporcional)
    my $atr_h = $self->{height_atr};
    my $atr_y = $atr_h / 2;

    # Dibujar crosshair en AMBOS paneles con el mismo X
    $self->_draw_crosshair_all($x, $y, $atr_y, $timestamp);

    # Actualizar etiqueta OHLCV arriba
    $self->_update_ohlcv_label($idx, $timestamp);
}

# Dibuja el crosshair en todos los paneles sincronizados.
# El eje X es identico en ambos (misma escala horizontal compartida).
sub _draw_crosshair_all {
    my ($self, $x, $y_price, $y_atr, $timestamp) = @_;
    $self->{price_panel}->draw_crosshair($x, $y_price, $timestamp);
    $self->{atr_panel}->draw_crosshair($x, $y_atr);
}

# Actualiza la etiqueta de informacion OHLCV en la parte superior.
sub _update_ohlcv_label {
    my ($self, $idx, $timestamp) = @_;
    return unless defined $self->{info_label};
    my $c = $self->{market_data}->get_candle($idx);
    return unless $c;
    my $ts_display = '';
    if (defined $timestamp && $timestamp =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/) {
        $ts_display = "T:$timestamp  ";
    }
    my $text = sprintf(
        "%sO:%.2f  H:%.2f  L:%.2f  C:%.2f  V:%d",
        $ts_display,
        $c->{open}, $c->{high}, $c->{low}, $c->{close}, $c->{volume}
    );
    $self->{info_label}->configure(-text => $text);
}

# Cambia la temporalidad del mercado y recalcula indicadores.
sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{market_data}->set_timeframe($tf);
    $self->{indicator_mgr}->reset_all();

    # Recalcular ATR con indice explicito para el nuevo timeframe
    my $atr  = $self->{indicator_mgr}->get('ATR');
    my $size = $self->{market_data}->size();
    for my $i (0 .. $size - 1) {
        $atr->update_last($self->{market_data}, $i);
    }
    $self->reset_view();
}

# Resetea zoom y desplazamiento al estado inicial (ultimas 100 velas).
sub reset_view {
    my ($self) = @_;
    my $total = $self->{market_data}->size();
    $self->{visible_bars} = 100 < $total ? 100 : $total;
    $self->{offset} = $total - $self->{visible_bars};
    $self->{offset} = 0 if $self->{offset} < 0;
    $self->request_render();
}

# Calcula etiquetas de tiempo para el eje X.
sub compute_intraday_labels {
    my ($self) = @_;
    return $self->{market_data}->compute_time_anchors();
}

# Devuelve timestamps de las velas visibles actualmente.
sub get_all_timestamps {
    my ($self) = @_;
    my ($candles) = $self->compute_window();
    return [ map { $_->{time} } @$candles ];
}

1;