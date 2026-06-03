package Market::ChartEngine;  
use strict;                   
use warnings; 
use utf8;                

use Time::Moment;             # Módulo para manejar fechas/horas de forma robusta
use Market::Panels::Scales;   # Nuestro sistema de coordenadas (datos ↔ píxeles)
use Market::Panels::PricePanel;   # Panel que dibuja las velas japonesas
use Market::Panels::ATRPanel;     # Panel que dibuja la línea del ATR


use constant {
    RIGHT_MARGIN     => 0,       # Margen derecho del área de ploteo (0 porque hay canvas separados)
    MIN_VISIBLE_BARS => 2,       # Mínimo de velas visibles (Req. 8, 10)
    MAX_VISIBLE_BARS => 800,     # Máximo de velas visibles
    DEFAULT_BARS     => 120,     # Número de velas visibles por defecto (zoom inicial)
    ZOOM_STEP        => 5,       # Barras por paso de rueda en zoom horizontal
    CTRL_MASK        => 0x0004,  # Máscara para detectar Ctrl presionado (X11)
    TIME_AXIS_DRAG_PX_PER_BAR => 8,  # Píxeles por barra en arrastre del eje temporal
    PRICE_TICK_SIZE  => 0.25,  # Tamaño del tick de precio para redondear (ajustable según el mercado)
};

# TEMAS: Funciones para obtener paletas de colores 
sub _dark_theme {
    return {
        name           => 'dark',
        bg             => '#1e1e2f',        # Fondo muy oscuro
        grid           => '#2a2a3e',        # Grid gris oscuro
        date_grid      => '#3a3a4e',        # Líneas de días
        axis_text      => '#a8aacb',        # Texto gris claro
        bull           => '#00d97d',        # Verde vibrante
        bear           => '#f6465d',        # Rojo vibrante
        atr_line       => '#1f77ff',        # Azul vibrante
        crosshair_line => '#808080',        # Gris para crosshair
        label_bg       => '#2a2a3e',        # Fondo etiquetas
        label_fg       => '#a8aacb',        # Texto etiquetas
        last_price_bg  => '#2a2a3e',        # Fondo último precio
        last_price_fg  => '#a8aacb',        # Texto último precio
        wick_bull      => '#00d97d',        # Mechas verdes
        wick_bear      => '#f6465d',        # Mechas rojas
        volume_bull    => '#00d97d80',      # Volumen alcista con transparencia
        volume_bear    => '#f6465d80',      # Volumen bajista con transparencia
    };
}

# new(): Constructor de ChartEngine
sub new {
    my ($class, %args) = @_;   
    my $self = {
        # Datos e indicadores (inyectados desde fuera)
        market_data      => $args{market_data},       # Objeto con los precios
        indicator_manager=> $args{indicator_manager}, # Contenedor de indicadores
        price_canvas     => $args{price_canvas},      # Canvas para velas
        atr_canvas       => $args{atr_canvas},        # Canvas para ATR
        price_axis_canvas => $args{price_axis_canvas},
        atr_axis_canvas   => $args{atr_axis_canvas},
        time_axis_canvas  => $args{time_axis_canvas},

         # Estado del zoom/scroll horizontal
        visible_bars     => DEFAULT_BARS,    # Cuántas velas se ven inicialmente (zoom por defecto)
        offset           => 0,     # Desplazamiento desde la derecha (0 = mostrar las más recientes)
        
        # Escala del eje Y (precios)
        is_auto_scale    => 1,     # 1 = escala automática, 0 = escala manual
        manual_min_y     => undef, # Mínimo Y en modo manual (si is_auto_scale=0)
        manual_max_y     => undef, # Máximo Y en modo manual
        
        # Control de render diferido (coalescing)
        render_pending   => 0,     # Flag: 1 si ya hay un render programado

    
        # Callback for scale mode changes
        scale_mode_callback => $args{scale_mode_callback},

        # Ctrl+Zoom state (nuevo de V2)
        ctrl_zoom_x_shift     => 0,
        ctrl_zoom_y_lock_min  => undef,
        ctrl_zoom_y_lock_max  => undef,
        
        # Chart mode: 'automatic' o 'manual'
        # Automático: solo scroll horizontal, escala Y automática
        # Manual: control total sobre X e Y
        chart_mode       => 'automatic',
        
        # Estado para arrastre horizontal (scroll con botón izquierdo)
        drag_start_x     => undef, # X inicial del arrastre (en píxeles)
        drag_start_y     => undef, # Y inicial del arrastre
        drag_start_offset=> 0,     # Offset al comenzar el arrastre
        drag_start_min_y  => undef,
        drag_start_max_y  => undef,
        drag_cursor_canvas=> undef,
        
        # Estado para arrastre del eje Y (zoom vertical manual)
        axis_drag_start_y=> undef, # Y inicial del arrastre en el eje lateral
        axis_drag_min_y  => undef, # Mínimo Y al comenzar el arrastre
        axis_drag_max_y  => undef, # Máximo Y al comenzar el arrastre
        
        # Estado para arrastre del eje Y (zoom vertical manual - ATR)
        atr_axis_drag_start_y => undef,
        atr_axis_drag_min_y   => undef,
        atr_axis_drag_max_y   => undef,
        atr_manual_min_y      => undef,
        atr_manual_max_y      => undef,
        atr_is_auto_scale     => 1,

        # Time axis drag
        time_axis_drag_start_x => undef,
        time_axis_drag_visible => undef,
        
        # Mouse state
        last_mouse_x      => undef,
        last_mouse_y      => undef,
        active_canvas     => undef,
        
        # Resize debounce
        _resize_pending   => 0,
        _printed_render_diag => 0,
        
        # Theme (DARK por defecto)
        theme_name        => $args{theme_name} // 'dark',
        
        %args,  
    };
    bless $self, $class;   # "Bendecir" el hashref como objeto de la clase

    # El tema viaja dentro de la instancia, nunca como variable global.
    if ($args{theme}) {
        $self->{theme} = $args{theme};
    } elsif ($args{dark_mode}) {
        $self->{theme} = _dark_theme();
    } 

    # Crear el panel de precios (inyectando canvas y tema)
    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas => $self->{price_canvas},
        theme  => $self->{theme},
        tick_size => $self->{tick_size},
    );
    
    # Crear el panel de ATR (inyectando canvas y tema)
    $self->{atr_panel}   = Market::Panels::ATRPanel->new(
        canvas => $self->{atr_canvas},
        theme  => $self->{theme},
    );

    # Conectar todos los eventos de ratón y teclado a los canvases
    $self->bind_events();
    
    return $self;   # Devolver el objeto recién creado
}

# compute_window: Calcula los índices GLOBALES de inicio y fin de la ventana visible
sub compute_window {
    my ($self) = @_;
    
    # Obtener cuántas velas hay en total en MarketData
    my $total_candles = $self->{market_data}->size();
    
    # Si no hay datos, devolver (0, -1) que indica ventana vacía
    return (0, -1) if !$total_candles || $total_candles <= 0;

    if ($total_candles >= MIN_VISIBLE_BARS) {
        # Si tenemos suficientes velas, aseguramos que visible_bars sea al menos MIN_VISIBLE_BARS
        $self->{visible_bars} = MIN_VISIBLE_BARS if $self->{visible_bars} < MIN_VISIBLE_BARS;
    } else {
        # Si hay menos velas que el mínimo, mostramos todas las que tenemos
        $self->{visible_bars} = $total_candles;
    }

    # No podemos mostrar más velas de las que existen
    $self->{visible_bars} = $total_candles if $self->{visible_bars} > $total_candles;
    
    # No podemos superar el máximo absoluto (por rendimiento)
    $self->{visible_bars} = MAX_VISIBLE_BARS if $self->{visible_bars} > MAX_VISIBLE_BARS;

    # Acotar el offset (scroll) dentro de los límites permitidos
    $self->{offset} = $self->_clamp_offset($self->{offset});

    # Calcular el índice de la última vela visible (más a la derecha)
    my $end_idx = $total_candles - 1 - $self->{offset};
    
    # Calcular el índice de la primera vela visible (más a la izquierda)
    my $start_idx = $end_idx - $self->{visible_bars} + 1;

    return ($start_idx, $end_idx);
}

# round: Redondea al entero más cercano (funciona con números positivos y negativos)
sub round {
    my ($self, $value) = @_;

    return 0 if !defined $value;   # Si no hay valor, devolver 0

    # Redondeo al entero más cercano: sumar 0.5 para positivos, restar 0.5 para negativos
    return int($value + ($value >= 0 ? 0.5 : -0.5));
}

# _max_offset_for_visible: Máximo offset permitido (scroll hacia la izquierda)
sub _max_offset_for_visible {
    my ($self) = @_;

    my $total = $self->{market_data}->size() || 0;
    return 0 if $total < MIN_VISIBLE_BARS;   # Si hay muy pocas velas, offset máximo = 0

    # El máximo offset es total - MIN_VISIBLE_BARS, pero no puede ser negativo
    return ($total - MIN_VISIBLE_BARS) > 0 ? ($total - MIN_VISIBLE_BARS) : 0;
}

# _min_offset_for_visible: Mínimo offset permitido (scroll hacia la derecha)
sub _min_offset_for_visible {
    my ($self) = @_;

    my $total = $self->{market_data}->size() || 0;
    return 0 if $total < MIN_VISIBLE_BARS;   # Si hay pocas velas, offset mínimo = 0

    my $visible = $self->{visible_bars} || MIN_VISIBLE_BARS;
    $visible = $total if $visible > $total;   # No puede superar el total

    # Representa cuántas velas "futuras" podemos mostrar a la izquierda
    return -(($visible > MIN_VISIBLE_BARS) ? ($visible - MIN_VISIBLE_BARS) : 0);
}

# _clamp_offset: Acota el offset dentro de los límites permitidos
sub _clamp_offset {
    my ($self, $offset) = @_;

    $offset = 0 if !defined $offset;                    # Si no hay offset, usar 0
    my $min_offset = $self->_min_offset_for_visible();  # Mínimo permitido (puede ser negativo)
    my $max_offset = $self->_max_offset_for_visible();  # Máximo permitido (positivo)
    $offset = $min_offset if $offset < $min_offset;     # No bajar del mínimo
    $offset = $max_offset if $offset > $max_offset;     # No superar el máximo
    return $offset;
}

# _pad_visible_slice: Rellena un slice con 'undef' para que tenga el tamaño exacto
sub _pad_visible_slice {
    my ($self, $slice, $start, $end) = @_;

    return unless $slice;   
    my $target = defined $start && defined $end && $end >= $start ? $end - $start + 1 : 0;
    # Si el slice actual es más corto, añadir undef hasta alcanzar el tamaño deseado
    push @$slice, (undef) x ($target - @$slice) if $target > @$slice;
}

# _canvas_width: Obtiene el ancho de un canvas Tk de forma robusta
sub _canvas_width {
    my ($self, $canvas) = @_;
    return 1 unless $canvas;   # Si no hay canvas, devolver 1

    my $w = 0;
    my $geom = eval { $canvas->geometry() };
    if (defined $geom && $geom =~ /^(\d+)x\d+/) {
        $w = $1;   # Extraer el ancho (primer número antes de la 'x')
    }
    # Si falló, probar con Width() o width()
    $w ||= eval { $canvas->Width() } || eval { $canvas->width() } || 1;
    return $w > 1 ? $w : 1;   # Asegurar que sea al menos 1
}

# _canvas_size: Obtiene ancho y alto de un canvas Tk
sub _canvas_size {
    my ($self, $canvas) = @_;
    return (1, 1) unless $canvas;   # Si no hay canvas, devolver (1,1)
    my ($w, $h) = (0, 0);
    my $geom = eval { $canvas->geometry() };
    if (defined $geom && $geom =~ /^(\d+)x(\d+)/) {
        ($w, $h) = ($1, $2);   # Extraer ancho y alto
    }
    $w ||= eval { $canvas->Width() }  || eval { $canvas->width() }  || 1;
    $h ||= eval { $canvas->Height() } || eval { $canvas->height() } || 1;
    $w = 1 if $w < 1;
    $h = 1 if $h < 1;
    return ($w, $h);
}

# _reset_canvas_view: Reinicia la vista de un canvas (scrollregion, etc.)
sub _reset_canvas_view {
    my ($self, $canvas) = @_;
    return unless $canvas;   # Si no hay canvas, salir

    my ($w, $h) = $self->_canvas_size($canvas);
    # Mover las barras de scroll a la posición inicial (0,0)
    eval { $canvas->xviewMoveto(0) };
    eval { $canvas->yviewMoveto(0) };
    # Configurar la región scrolleable al tamaño exacto del canvas
    eval { $canvas->configure(-scrollregion => [0, 0, $w, $h]) };
}

# request_render: Programa un render diferido (coalescing)
# request_render: Programa un render diferido (VERSIÓN CORREGIDA)
sub request_render {
    my ($self) = @_;

    return if $self->{render_pending};
    $self->{render_pending} = 1;
    
    # Guardar el estado del mouse ANTES del render diferido
    my $saved_mouse_x = $self->{last_mouse_x};
    my $saved_mouse_y = $self->{last_mouse_y};
    my $saved_active = $self->{active_canvas};

    my $canvas = $self->{price_canvas} || $self->{atr_canvas};
    if ($canvas) {
        $canvas->after(20, sub {
            $self->{render_pending} = 0;
            $self->render();
            
            # RESTAURAR el estado del mouse después del render
            if (defined $saved_mouse_x) {
                $self->{last_mouse_x} = $saved_mouse_x;
                $self->{last_mouse_y} = $saved_mouse_y if defined $saved_mouse_y;
                $self->{active_canvas} = $saved_active if defined $saved_active;
                $self->_draw_crosshair_all();
            }
        });
    } else {
        $self->{render_pending} = 0;
        $self->render();
    }
}

# render: MÉTODO PRINCIPAL de dibujo (el corazón del motor gráfico)
sub render {
    my ($self) = @_;
    
    # 1. Obtener la porción temporal de la ventana visible
    my ($start, $end) = $self->compute_window();
    
    # 2. Extraer subconjuntos de datos reales (solo las velas visibles)
    my $visible_candles = $self->{market_data}->get_slice($start, $end);
    my $visible_atr     = $self->{indicator_manager}->slice_array('ATR', $start, $end);
    
    # Asegurar que los slices tengan el tamaño correcto
    $self->_pad_visible_slice($visible_candles, $start, $end);
    $self->_pad_visible_slice($visible_atr, $start, $end);
    
    # 3. Calcular rangos de precios e indicadores para construir escalas dinámicas
    my ($min_p, $max_p) = $self->{price_panel}->get_y_range($visible_candles);
    my ($min_a, $max_a) = $self->{atr_panel}->get_y_range($visible_atr);
    
    # Si estamos en modo manual, usar los valores manuales
    if (defined $self->{ctrl_zoom_y_lock_min} && defined $self->{ctrl_zoom_y_lock_max}) {
        ($min_p, $max_p) = ($self->{ctrl_zoom_y_lock_min}, $self->{ctrl_zoom_y_lock_max});
    } elsif (!$self->{is_auto_scale} && defined $self->{manual_min_y} && defined $self->{manual_max_y}) {
        ($min_p, $max_p) = ($self->{manual_min_y}, $self->{manual_max_y});
    } else {
        ($self->{manual_min_y}, $self->{manual_max_y}) = ($min_p, $max_p);
    }

    # Rangos por defecto si hay problemas (ej: sin datos o rango cero)
    if (!defined $min_p || !defined $max_p || $min_p == $max_p) {
        $min_p = 20000;   # Valor típico para Bitcoin
        $max_p = 30000;
    }
    if (!defined $min_a || !defined $max_a || $min_a == $max_a) {
        $min_a = 0;
        $max_a = 100;
    }

    # Aplicar override manual del ATR si existe (zoom/pan independiente)
    if (!$self->{atr_is_auto_scale} && defined $self->{atr_manual_min_y} && defined $self->{atr_manual_max_y}) {
        ($min_a, $max_a) = ($self->{atr_manual_min_y}, $self->{atr_manual_max_y});
    } else {
        # Modo automático: actualizar los valores manuales con el rango calculado
        ($self->{atr_manual_min_y}, $self->{atr_manual_max_y}) = ($min_a, $max_a);
    }
    
    # 4. Instanciar los sistemas de coordenadas (Scales)
    my ($price_w, $price_h) = $self->_canvas_size($self->{price_canvas});
    my ($atr_w, $atr_h)     = $self->_canvas_size($self->{atr_canvas});
    my $shared_w = $price_w;   # Ambos paneles usan el mismo ancho para el eje X

    # Resetear las vistas de los canvases 
    $self->_reset_canvas_view($self->{price_canvas});
    $self->_reset_canvas_view($self->{atr_canvas});
    $self->_reset_canvas_view($self->{price_axis_canvas});
    $self->_reset_canvas_view($self->{atr_axis_canvas});
    $self->_reset_canvas_view($self->{time_axis_canvas});

    # Mensaje de diagnóstico 
    if (!$self->{_printed_render_diag}) {
        print "[*] Render geometry: price=${price_w}x${price_h} atr=${atr_w}x${atr_h} window=$start-$end bars=" . scalar(@$visible_candles) . "\n";
        $self->{_printed_render_diag} = 1;
    }

    # Calcular cuántas barras hay en la ventana visible
    my $x_bars = $end - $start + 1;
    $x_bars = scalar(@$visible_candles) if $x_bars < 1;
    $x_bars = 1 if $x_bars < 1;

    # Crear la escala de precios y la escala de ATR (mismos parámetros X)
    my $price_scale = Market::Panels::Scales->new(min_y => $min_p, max_y => $max_p, bars => $x_bars, right_margin => RIGHT_MARGIN);
    my $atr_scale   = Market::Panels::Scales->new(min_y => $min_a, max_y => $max_a, bars => $x_bars, right_margin => RIGHT_MARGIN);
    
    # Inyectar dimensiones reales del canvas en las escalas
    $price_scale->{width}  = $shared_w;
    $price_scale->{height} = $price_h;
    $atr_scale->{width}    = $shared_w;
    $atr_scale->{height}   = $atr_h;
    
    # Configurar flags de dibujo según si hay ejes separados o no
    $price_scale->{draw_labels} = $self->{price_axis_canvas} ? 0 : 1;
    $price_scale->{draw_last_label} = $self->{price_axis_canvas} ? 0 : 1;
    $price_scale->{draw_crosshair_label} = $self->{price_axis_canvas} ? 0 : 1;
    $price_scale->{x_shift} = $self->{ctrl_zoom_x_shift} || 0;
    $atr_scale->{draw_labels} = $self->{atr_axis_canvas} ? 0 : 1;
    $atr_scale->{draw_last_label} = $self->{atr_axis_canvas} ? 0 : 1;
    $atr_scale->{x_shift} = $self->{ctrl_zoom_x_shift} || 0;

    # Asignar las escalas a los paneles
    $self->{price_panel}->set_scale($price_scale);
    $self->{atr_panel}->set_scale($atr_scale);
    
    # 5. Ejecutar render en cada sub-canvas
    $self->{price_panel}->render($self->{price_canvas}, $visible_candles, $price_scale);
    $self->{atr_panel}->render($self->{atr_canvas}, $visible_atr, $atr_scale);
    
    # Calcular etiquetas del eje temporal y dibujarlas en el panel de precios
    my $time_labels = $self->compute_intraday_labels();
    $self->{price_panel}->draw_time_axis($self->{price_canvas}, $time_labels, { draw_grid => 1, draw_labels => 0 });
    
    # Dibujar los ejes laterales (Y) y el eje temporal inferior
    $self->_render_price_axis($price_scale, $visible_candles);
    $self->_render_atr_axis($atr_scale, $visible_atr);
    $self->_render_time_axis($price_scale, $time_labels);
}

# _render_price_axis: Dibuja el eje Y lateral del panel de precios
sub _render_price_axis {
    my ($self, $source_scale, $visible_candles) = @_;

    my $canvas = $self->{price_axis_canvas};
    return unless $canvas && $source_scale;   # Si no hay canvas o escala, salir

    my ($w, $h) = $self->_canvas_size($canvas);
    $canvas->delete('y_scale');           # Borrar etiquetas anteriores
    $canvas->delete('axis_last_price');   # Borrar etiqueta del último precio

    # Crear una escala para el eje Y 
    my $axis_scale = Market::Panels::Scales->new(
        min_y        => $source_scale->{min_y},
        max_y        => $source_scale->{max_y},
        bars         => 1,               # Solo una barra
        right_margin => 0,
    );
    $axis_scale->{width}           = $w;
    $axis_scale->{height}          = $source_scale->{height} || $h;
    $axis_scale->{draw_grid}       = 0;   # No dibujar líneas de grid en el eje lateral
    $axis_scale->{draw_labels}     = 1;   # Sí dibujar etiquetas numéricas
    $axis_scale->{label_x}         = 4;   # Posición X para el texto
    $axis_scale->{label_anchor}    = 'w'; # Anclaje 'w' = oeste (izquierda)
    $axis_scale->{grid_color}      = $self->{theme}{grid}      // '#e7dfdb';
    $axis_scale->{axis_text_color} = $self->{theme}{axis_text} // '#373544';
    $axis_scale->_draw_y_scale($canvas);   # Dibujar el eje Y

    # Encontrar la última vela definida
    return unless $visible_candles && @$visible_candles;
    my $last_candle;
    for my $candle (@$visible_candles) {
        $last_candle = $candle if defined $candle;
    }
    return unless defined $last_candle;
    my ($open, $close) = @{$last_candle}[1, 4];   # open está en índice 1, close en 4
    return unless defined $close;

    # Convertir precio de cierre a coordenada Y
    my $y = $axis_scale->value_to_y($close);

    my $label = sprintf('%.2f', $close);
    # Color de fondo: verde para alcista, rojo para bajista
    my $bg = (defined $open && $close >= $open)
        ? ($self->{theme}{bull} // '#1daba7')
        : ($self->{theme}{bear} // '#ee423f');
    my $fg = $self->{theme}{last_price_fg} // '#ffffff';

    # Dibujar rectángulo de fondo y texto del último precio
    $canvas->createRectangle(0, $y - 8, $w, $y + 8, -fill => $bg, -outline => $bg, -tags => 'axis_last_price');
    $canvas->createText(4, $y, -text => $label, -anchor => 'w', -font => 'Helvetica 9 bold', -fill => $fg, -tags => 'axis_last_price');
}



# _draw_price_axis_crosshair: Dibuja el crosshair en el eje lateral de precios
sub _draw_price_axis_crosshair {
    my ($self, $y) = @_;

    my $canvas = $self->{price_axis_canvas};
    return unless $canvas;

    $canvas->delete('axis_crosshair');
    return unless defined $y;

    my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
    return unless $scale;

    my ($w, undef) = $self->_canvas_size($canvas);
    my $raw_value = $scale->y_to_value($y);

    # Redondear al tick más cercano (0.25)
    my $tick = $self->{tick_size} // PRICE_TICK_SIZE;
    my $value = int($raw_value / $tick + 0.5) * $tick;

    my $label = sprintf('%.2f', $value);
    my $bg = $self->{theme}{label_bg} // '#343e45';
    my $fg = $self->{theme}{label_fg} // '#ffffff';

    $canvas->createRectangle(0, $y - 8, $w, $y + 8, -fill => $bg, -outline => $bg, -tags => 'axis_crosshair');
    $canvas->createText(4, $y, -text => $label, -anchor => 'w', -font => 'Helvetica 9 bold', -fill => $fg, -tags => 'axis_crosshair');
}

# _draw_atr_axis_crosshair: Dibuja el crosshair en el eje lateral del ATR

sub _draw_atr_axis_crosshair {
    my ($self, $y) = @_;

    my $canvas = $self->{atr_axis_canvas};
    return unless $canvas;

    $canvas->delete('atr_axis_crosshair');
    return unless defined $y;

    my $scale = $self->{atr_panel} ? $self->{atr_panel}->{scale} : undef;
    return unless $scale;

    my ($w, undef) = $self->_canvas_size($canvas);
    my $value = $scale->y_to_value($y);   # Convertir Y a valor ATR
    my $label = sprintf('%.4f', $value);  # ATR tiene más decimales
    my $bg = $self->{theme}{label_bg} // '#343e45';
    my $fg = $self->{theme}{label_fg} // '#ffffff';

    $canvas->createRectangle(0, $y - 8, $w, $y + 8, -fill => $bg, -outline => $bg, -tags => 'atr_axis_crosshair');
    $canvas->createText(4, $y, -text => $label, -anchor => 'w', -font => 'Helvetica 9 bold', -fill => $fg, -tags => 'atr_axis_crosshair');
}

# _render_time_axis: Dibuja el eje temporal inferior 
sub _render_time_axis {
    my ($self, $source_scale, $labels) = @_;

    my $canvas = $self->{time_axis_canvas};
    return unless $canvas && $source_scale;

    my ($w, $h) = $self->_canvas_size($canvas);
    my $old_scale = $self->{price_panel}->{scale};   # Guardar escala anterior del panel de precios
    my $axis_scale = Market::Panels::Scales->new(
        bars         => $source_scale->{bars},
        right_margin => RIGHT_MARGIN,
    );
    $axis_scale->{width}  = $source_scale->{width} || $w;
    $axis_scale->{height} = $h;

    # Reemplazar temporalmente la escala del panel de precios por la del eje
    $self->{price_panel}->{scale} = $axis_scale;
    $self->{price_panel}->draw_time_axis($canvas, $labels, { draw_grid => 0, draw_labels => 1 });
    # Restaurar la escala original
    $self->{price_panel}->{scale} = $old_scale;
}

# _render_atr_axis: Dibuja el eje Y lateral del panel ATR
sub _render_atr_axis {
    my ($self, $source_scale, $visible_atr) = @_;

    my $canvas = $self->{atr_axis_canvas};
    return unless $canvas && $source_scale;

    my ($w, $h) = $self->_canvas_size($canvas);
    $canvas->delete('y_scale');
    $canvas->delete('atr_axis_last');

    my $axis_scale = Market::Panels::Scales->new(
        min_y        => $source_scale->{min_y},
        max_y        => $source_scale->{max_y},
        bars         => 1,
        right_margin => 0,
    );
    $axis_scale->{width}           = $w;
    $axis_scale->{height}          = $source_scale->{height} || $h;
    $axis_scale->{draw_grid}       = 0;
    $axis_scale->{draw_labels}     = 1;
    $axis_scale->{label_x}         = 4;
    $axis_scale->{label_anchor}    = 'w';
    $axis_scale->{grid_color}      = $self->{theme}{grid}      // '#e7dfdb';
    $axis_scale->{axis_text_color} = $self->{theme}{axis_text} // '#373544';
    $axis_scale->_draw_y_scale($canvas);

    # Encontrar el último valor ATR definido
    my $last;
    for my $v (@$visible_atr) {
        $last = $v if defined $v;
    }
    return unless defined $last;

    my $y = $axis_scale->value_to_y($last);
    my $label = sprintf('%.4f', $last);
    my $fg = $self->{theme}{last_price_fg} // '#ffffff';
    my $line = $self->{theme}{atr_line} // '#2962ff';

    # Dibujar rectángulo con el color de la línea ATR
    $canvas->createRectangle(0, $y - 8, $w, $y + 8, -fill => $line, -outline => $line, -tags => 'atr_axis_last');
    $canvas->createText(4, $y, -text => $label, -anchor => 'w', -font => 'Helvetica 9 bold', -fill => $fg, -tags => 'atr_axis_last');
}

# _bind_all_canvas: Conecta TODOS los eventos de Tk a los canvases
sub _bind_all_canvas {
    my ($self) = @_;
    
    # Obtener referencias a los canvases (por claridad)
    my $p_canvas = $self->{price_canvas};
    my $a_canvas = $self->{atr_canvas};
    my $axis_canvas = $self->{price_axis_canvas};
    my $time_canvas = $self->{time_axis_canvas};
    
    # 1. Binding para el panel de precios
    if (defined $p_canvas) {
        # Movimiento del ratón: actualiza coordenadas y dibuja crosshair
        $p_canvas->Tk::bind('<Motion>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_on_mouse_move($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        
        # Presionar botón izquierdo: iniciar arrastre horizontal (scroll)
        $p_canvas->Tk::bind('<ButtonPress-1>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_start_horizontal_drag($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        
        # Arrastre con botón presionado: desplazar el gráfico horizontalmente
        $p_canvas->Tk::bind('<B1-Motion>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_on_horizontal_drag($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        
        # Soltar botón: limpiar estado del arrastre
        $p_canvas->Tk::bind('<ButtonRelease-1>', sub { $self->_end_drag(); });
        
        # Rueda del ratón (estándar en Windows/Linux moderno)
        $p_canvas->Tk::bind('<MouseWheel>', [sub {
            my ($widget, $delta, $x, $y, $state) = @_;
            my $step = $delta > 0 ? -ZOOM_STEP : ZOOM_STEP;  # Delta positivo = scroll hacia arriba → zoom in
            $self->_wheel_zoom($widget, $step, $x, $y, $state);
            return 'break';   # Evitar que Tk también procese el evento
        }, Tk::Ev('D'), Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        
        # Rueda en X11 (Button-4 = scroll up, Button-5 = scroll down)
        $p_canvas->Tk::bind('<Button-4>', [sub {
            my ($widget, $x, $y, $state) = @_;
            $self->_wheel_zoom($widget, -ZOOM_STEP, $x, $y, $state);
            return 'break';
        }, Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        $p_canvas->Tk::bind('<Button-5>', [sub {
            my ($widget, $x, $y, $state) = @_;
            $self->_wheel_zoom($widget, ZOOM_STEP, $x, $y, $state);
            return 'break';
        }, Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        
        # Doble clic: resetear vista (zoom 60 velas, offset 0, auto escala)
        $p_canvas->Tk::bind('<Double-Button-1>', sub { $self->reset_view(); });
        
        # Redimensionamiento de la ventana: reprogramar render
        $p_canvas->Tk::bind('<Configure>', sub { $self->_on_resize($p_canvas); });
        
        # Teclas para control de modo (Automático/Manual) y escala Y
        $p_canvas->Tk::bind('<Key-A>', sub { $self->set_chart_mode('automatic'); });  # 'A' → modo automático
        $p_canvas->Tk::bind('<Key-M>', sub { $self->set_chart_mode('manual'); });     # 'M' → modo manual
        $p_canvas->Tk::bind('<Key-a>', sub { $self->set_scale_mode('auto'); });   # 'a' → auto escala (legacy)
        $p_canvas->Tk::bind('<Key-m>', sub { $self->set_scale_mode('manual'); });  # 'm' → manual escala (legacy)
        $p_canvas->Tk::bind('<Key-t>', sub { $self->toggle_theme(); });
        $p_canvas->Tk::bind('<Key-plus>', sub { $self->{is_auto_scale} = 0; $self->_vertical_zoom(0.9); });   # '+' → zoom in
        $p_canvas->Tk::bind('<Key-minus>', sub { $self->{is_auto_scale} = 0; $self->_vertical_zoom(1.1); });  # '-' → zoom out
        $p_canvas->Tk::bind('<Up>', sub { $self->{is_auto_scale} = 0; $self->_vertical_drag(-10); });    # Flecha arriba → pan up
        $p_canvas->Tk::bind('<Down>', sub { $self->{is_auto_scale} = 0; $self->_vertical_drag(10); });   # Flecha abajo → pan down
        
        # Enfoque: cuando el mouse entra, dar foco al canvas para capturar teclas
        $p_canvas->Tk::bind('<Enter>', sub { $p_canvas->focus; });
        
        # Cuando el mouse sale del canvas, ocultar el crosshair
        $p_canvas->Tk::bind('<Leave>', sub {
            $self->{last_mouse_x} = undef;
            $self->{last_mouse_y} = undef;
            $self->{active_canvas} = undef;
            $self->_draw_crosshair_all();
        });
    }
    
    # 2. Binding idéntico para el panel del ATR
    if (defined $a_canvas) {
        $a_canvas->Tk::bind('<Motion>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_on_mouse_move($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        
        $a_canvas->Tk::bind('<ButtonPress-1>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_start_horizontal_drag($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        
        $a_canvas->Tk::bind('<B1-Motion>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_on_horizontal_drag($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        
        $a_canvas->Tk::bind('<ButtonRelease-1>', sub { $self->_end_drag(); });
        
        $a_canvas->Tk::bind('<MouseWheel>', [sub {
            my ($widget, $delta, $x, $y, $state) = @_;
            my $step = $delta > 0 ? -ZOOM_STEP : ZOOM_STEP;
            $self->_wheel_zoom($widget, $step, $x, $y, $state);
            return 'break';
        }, Tk::Ev('D'), Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        
        $a_canvas->Tk::bind('<Button-4>', [sub {
            my ($widget, $x, $y, $state) = @_;
            $self->_wheel_zoom($widget, -ZOOM_STEP, $x, $y, $state);
            return 'break';
        }, Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        
        $a_canvas->Tk::bind('<Button-5>', [sub {
            my ($widget, $x, $y, $state) = @_;
            $self->_wheel_zoom($widget, ZOOM_STEP, $x, $y, $state);
            return 'break';
        }, Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        
        $a_canvas->Tk::bind('<Configure>', sub { $self->_on_resize($a_canvas); });
        $a_canvas->Tk::bind('<Leave>', sub {
            $self->{last_mouse_x} = undef;
            $self->{last_mouse_y} = undef;
            $self->{active_canvas} = undef;
            $self->_draw_crosshair_all();
        });
    }

    # 3. Binding para el eje lateral de precios (zoom Y manual)
    if (defined $axis_canvas) {
        $axis_canvas->Tk::bind('<ButtonPress-1>', [sub {
            my ($widget, $y) = @_;
            $self->_start_price_axis_drag($widget, $y);
        }, Tk::Ev('y')]);
        $axis_canvas->Tk::bind('<B1-Motion>', [sub {
            my ($widget, $y) = @_;
            $self->_on_price_axis_drag($widget, $y);
        }, Tk::Ev('y')]);
        $axis_canvas->Tk::bind('<ButtonRelease-1>', sub { $self->_end_price_axis_drag(); });
        $axis_canvas->Tk::bind('<Double-Button-1>', sub { $self->set_scale_mode('auto'); });
        $axis_canvas->Tk::bind('<Enter>', sub { eval { $axis_canvas->configure(-cursor => 'sb_v_double_arrow') } });
    }
 # 3b. NUEVO: Binding para el eje lateral del ATR (zoom Y manual del indicador)
    my $atr_axis = $self->{atr_axis_canvas};
    if (defined $atr_axis) {
        $atr_axis->Tk::bind('<ButtonPress-1>', [sub {
            my ($widget, $y) = @_;
            $self->_start_atr_axis_drag($widget, $y);
        }, Tk::Ev('y')]);
        $atr_axis->Tk::bind('<B1-Motion>', [sub {
            my ($widget, $y) = @_;
            $self->_on_atr_axis_drag($widget, $y);
        }, Tk::Ev('y')]);
        $atr_axis->Tk::bind('<ButtonRelease-1>', sub { $self->_end_atr_axis_drag(); });
        $atr_axis->Tk::bind('<Double-Button-1>', sub {
            $self->{atr_is_auto_scale} = 1;
            $self->{atr_manual_min_y}  = undef;
            $self->{atr_manual_max_y}  = undef;
            $self->request_render();
        });
        $atr_axis->Tk::bind('<Enter>', sub {
            eval { $atr_axis->configure(-cursor => 'sb_v_double_arrow') }
        });
    }

    # 4. Binding para el eje temporal inferior (zoom horizontal con arrastre)
    if (defined $time_canvas) {
        $time_canvas->Tk::bind('<Motion>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_on_time_axis_motion($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        $time_canvas->Tk::bind('<ButtonPress-1>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_start_time_axis_drag($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        $time_canvas->Tk::bind('<B1-Motion>', [sub {
            my ($widget, $x, $y) = @_;
            $self->_on_time_axis_drag($widget, $x, $y);
        }, Tk::Ev('x'), Tk::Ev('y')]);
        $time_canvas->Tk::bind('<ButtonRelease-1>', sub { $self->_end_time_axis_drag(); });
        $time_canvas->Tk::bind('<MouseWheel>', [sub {
            my ($widget, $delta, $x, $y, $state) = @_;
            my $step = $delta > 0 ? -ZOOM_STEP : ZOOM_STEP;
            $self->_wheel_zoom($widget, $step, $x, $y, $state);
            return 'break';
        }, Tk::Ev('D'), Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        $time_canvas->Tk::bind('<Button-4>', [sub {
            my ($widget, $x, $y, $state) = @_;
            $self->_wheel_zoom($widget, -ZOOM_STEP, $x, $y, $state);
            return 'break';
        }, Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        $time_canvas->Tk::bind('<Button-5>', [sub {
            my ($widget, $x, $y, $state) = @_;
            $self->_wheel_zoom($widget, ZOOM_STEP, $x, $y, $state);
            return 'break';
        }, Tk::Ev('x'), Tk::Ev('y'), Tk::Ev('s')]);
        $time_canvas->Tk::bind('<Enter>', sub { eval { $time_canvas->configure(-cursor => 'sb_h_double_arrow') } });
        $time_canvas->Tk::bind('<Leave>', sub {
            $self->{last_mouse_x} = undef;
            $self->{last_mouse_y} = undef;
            $self->{active_canvas} = undef;
            $self->_draw_crosshair_all();
        });
    }
}

# bind_events: Punto de entrada para conectar eventos 
sub bind_events {
    my ($self) = @_;
    $self->_bind_all_canvas();
}

# _anchor_index_and_x: Calcula el punto de anclaje para zoom con anclaje
sub _anchor_index_and_x {
    my ($self, $anchor_x) = @_;

    my ($start, $end) = $self->compute_window();
    my $bars = $end - $start + 1;
    $bars = 1 if $bars < 1;

    my $scale = Market::Panels::Scales->new(
        bars         => $bars,
        right_margin => RIGHT_MARGIN,
    );
    $scale->{width} = $self->_canvas_width($self->{price_canvas});

    my $local  = $scale->x_to_index_float($anchor_x) - 0.5;
    my $global = $start + $local;
    $global = 0 if $global < 0;
    $global = $self->{market_data}->last_index() if $global > $self->{market_data}->last_index();

    return ($global, $anchor_x);
}

# _zoom_anchor_x: Decide si usar anclaje de cursor o no
sub _zoom_anchor_x {
    my ($self) = @_;

    my $x = $self->{last_mouse_x};
    return undef unless defined $x;   # Sin cursor → ancla = última vela

    my $canvas = $self->{price_canvas};
    return undef unless $canvas;
    my $w = $self->_canvas_width($canvas);
    return undef unless defined $w && $w > 0;

    my ($start, $end) = $self->compute_window();
    my $bars = $end - $start + 1;
    $bars = 1 if $bars < 1;

    my $scale = Market::Panels::Scales->new(
        bars         => $bars,
        right_margin => RIGHT_MARGIN,
    );
    $scale->{width} = $w;
    my $plot_w = $scale->plot_width();   # Ancho del área de ploteo

    return ($x >= 0 && $x <= $plot_w) ? $x : undef;
}

# Limpiar estado de Ctrl+Zoom 
sub _clear_ctrl_zoom_state {
    my ($self) = @_;
    $self->{ctrl_zoom_x_shift} = 0;
    $self->{ctrl_zoom_y_lock_min} = undef;
    $self->{ctrl_zoom_y_lock_max} = undef;
}

# _wheel_zoom: Maneja el evento de la rueda del ratón
# _wheel_zoom: Maneja el evento de la rueda del ratón (VERSIÓN CORREGIDA)
sub _wheel_zoom {
    my ($self, $widget, $step, $x, $y, $state) = @_;

    # GUARDAR posición actual del cursor ANTES de hacer zoom
    my $saved_x = defined $x ? $self->round($x) : $self->{last_mouse_x};
    my $saved_y = defined $y ? $self->round($y) : $self->{last_mouse_y};
    my $saved_widget = $widget || $self->{active_canvas};
    
    # Verificar si Ctrl está presionado
    my $ctrl_pressed = defined $state && ($state & CTRL_MASK);
    
    # Aplicar el zoom
    if ($ctrl_pressed) {
        my $anchor_x = $self->_zoom_anchor_x();
        if (defined $anchor_x) {
            $self->_ctrl_horizontal_zoom($step, $anchor_x);
        } else {
            $self->_horizontal_zoom($step, undef);
        }
    } else {
        $self->_clear_ctrl_zoom_state();
        $self->_horizontal_zoom($step, undef);
    }
    
    # RESTAURAR la posición del cursor después del zoom
    if (defined $saved_x) {
        $self->{last_mouse_x} = $saved_x;
        $self->{last_mouse_y} = $saved_y if defined $saved_y;
        $self->{active_canvas} = $saved_widget if defined $saved_widget;
        
        # Forzar ACTUALIZACIÓN INMEDIATA del crosshair
        $self->_draw_crosshair_all();
    }
}

# _horizontal_zoom: Zoom horizontal con anclaje 
sub _ctrl_horizontal_zoom {
    my ($self, $delta, $anchor_x) = @_;
    
    my $total = $self->{market_data}->size();
    return if !$total;
    
    my ($start, $end) = $self->compute_window();
    my $old_visible = $self->{visible_bars} || ($end - $start + 1) || 1;
    my $max_visible = $total < MAX_VISIBLE_BARS ? $total : MAX_VISIBLE_BARS;
    $max_visible = MIN_VISIBLE_BARS if $max_visible < MIN_VISIBLE_BARS;
    
    my $new_visible = $old_visible + $delta;
    $new_visible = MIN_VISIBLE_BARS if $new_visible < MIN_VISIBLE_BARS;
    $new_visible = $max_visible if $new_visible > $max_visible;
    return if $new_visible == $old_visible;
    
    my $canvas_w = $self->_canvas_width($self->{price_canvas});
    return if !$canvas_w || $canvas_w <= 0;
    
    my $old_scale = Market::Panels::Scales->new(bars => $old_visible, right_margin => RIGHT_MARGIN);
    $old_scale->{width} = $canvas_w;
    $old_scale->{x_shift} = $self->{ctrl_zoom_x_shift} || 0;
    
    my $anchor_global = $start + $old_scale->x_to_index_float($anchor_x) - 0.5;
    
    my $new_scale = Market::Panels::Scales->new(bars => $new_visible, right_margin => RIGHT_MARGIN);
    $new_scale->{width} = $canvas_w;
    my $new_bar_w = $new_scale->plot_width() / $new_visible;
    return if $new_bar_w <= 0;
    
    my $target_start = $anchor_global - (($anchor_x - ($new_bar_w / 2)) / $new_bar_w);
    my $new_start = $self->round($target_start);
    my $new_end = $new_start + $new_visible - 1;
    my $new_offset = ($total - 1) - $new_end;
    
    $self->{visible_bars} = $new_visible;
    $self->{offset} = $self->_clamp_offset($new_offset);
    
    ($new_start, $new_end) = $self->compute_window();
    $self->{ctrl_zoom_x_shift} = $anchor_x - (($anchor_global - $new_start + 0.5) * $new_bar_w);
    
    if ($self->{is_auto_scale}) {
        $self->{ctrl_zoom_y_lock_min} = undef;
        $self->{ctrl_zoom_y_lock_max} = undef;
    } elsif (!defined $self->{ctrl_zoom_y_lock_min} || !defined $self->{ctrl_zoom_y_lock_max}) {
        if (defined $self->{manual_min_y} && defined $self->{manual_max_y}) {
            $self->{ctrl_zoom_y_lock_min} = $self->{manual_min_y};
            $self->{ctrl_zoom_y_lock_max} = $self->{manual_max_y};
        }
    }
    
    $self->request_render();
}

# ============================================================================
# _start_horizontal_drag: Inicia un arrastre horizontal (scroll)
# ============================================================================
sub _start_horizontal_drag {
    my ($self, $widget, $x, $y) = @_;

    # Obtener coordenadas absolutas del ratón (en la pantalla, no solo en el widget)
    my $root_x = eval { $widget->pointerx() };
    my $root_y = eval { $widget->pointery() };
    $self->{drag_start_x} = defined $root_x ? $root_x : $x;
    $self->{drag_start_y} = defined $root_y ? $root_y : $y;
    $self->{drag_start_offset} = $self->{offset};   # Guardar offset inicial

    # Cambiar el cursor a "mano" para indicar que se puede arrastrar
    if (defined $widget && defined $self->{price_canvas} && $widget == $self->{price_canvas}) {
        eval { $widget->configure(-cursor => 'hand2') };
        $self->{drag_cursor_canvas} = $widget;
    }

    # Guardar rango Y actual (para posible arrastre vertical simultáneo)
    my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
    $self->{drag_start_min_y} = defined $self->{manual_min_y} ? $self->{manual_min_y} : (defined $scale ? $scale->{min_y} : undef);
    $self->{drag_start_max_y} = defined $self->{manual_max_y} ? $self->{manual_max_y} : (defined $scale ? $scale->{max_y} : undef);
}

# ============================================================================
# _on_horizontal_drag: Maneja el movimiento durante un arrastre horizontal
# Comportamiento diferente según chart_mode:
#   - 'automatic': solo scroll X, escala Y automática
#   - 'manual': scroll X + pan Y simultáneo
# ============================================================================
sub _on_horizontal_drag {
    my ($self, $widget, $x, $y) = @_;

    $self->_on_mouse_move($widget, $x, $y);   # Actualizar crosshair
    return unless defined $self->{drag_start_x};
    my $canvas = $self->{price_canvas};
    return unless $canvas;

    # Obtener posición actual del ratón (absoluta)
    my $root_x = eval { $widget->pointerx() };
    my $root_y = eval { $widget->pointery() };
    my $current_x = defined $root_x ? $root_x : $x;
    my $current_y = defined $root_y ? $root_y : $y;
    
    # Obtener ancho de barra actual
    my $width = $self->_canvas_width($canvas);
    my $scale = Market::Panels::Scales->new(
        bars         => $self->{visible_bars} || 1,
        right_margin => RIGHT_MARGIN,
    );
    $scale->{width} = $width;
    my $bar_w = $scale->plot_width() / ($self->{visible_bars} || 1);
    return if $bar_w <= 0;

    # Calcular desplazamiento en barras (píxeles movidos / ancho de barra)
    my $delta_bars = int(($current_x - $self->{drag_start_x}) / $bar_w);
    $self->{offset} = $self->_clamp_offset($self->{drag_start_offset} + $delta_bars);
    
    # En modo automático: forzar escala Y automática, NO permitir pan vertical
    # En modo manual: permitir arrastre vertical simultáneo (pan Y)
    if ($self->{chart_mode} eq 'automatic') {
        # Modo automático: solo scroll horizontal, mantener escala automática
        $self->{is_auto_scale} = 1;
        $self->{manual_min_y} = undef;
        $self->{manual_max_y} = undef;
    } else {
        # Modo manual: permitir arrastre vertical si corresponde
        $self->_apply_vertical_drag_from_start($current_y);
    }
    
    $self->request_render();   # Reprogramar render
}

# _horizontal_zoom: Zoom horizontal estándar (VERSIÓN CORREGIDA)
sub _horizontal_zoom {
    my ($self, $delta, $anchor_x) = @_;

    my $total = $self->{market_data}->size();
    return unless $total && $total > 0;

    my $old_visible = $self->{visible_bars};
    my $new_visible = $old_visible + $delta;

    my $max_visible = $total < MAX_VISIBLE_BARS ? $total : MAX_VISIBLE_BARS;
    $new_visible = MIN_VISIBLE_BARS if $new_visible < MIN_VISIBLE_BARS;
    $new_visible = $max_visible     if $new_visible > $max_visible;

    return if $new_visible == $old_visible;

    my ($anchor_global, $anchor_screen_x);

    if (defined $anchor_x) {
        # Zoom con anclaje en la posición del cursor
        ($anchor_global, $anchor_screen_x) = $self->_anchor_index_and_x($anchor_x);
    } else {
        # Zoom sin anclaje específico: usar el centro visible O la posición del mouse si existe
        my ($start, $end) = $self->compute_window();
        
        # Si tenemos posición del mouse guardada, usarla como anclaje
        if (defined $self->{last_mouse_x}) {
            my $mouse_x = $self->{last_mouse_x};
            my $canvas_w = $self->_canvas_width($self->{price_canvas});
            if ($canvas_w && $canvas_w > 0 && $mouse_x >= 0 && $mouse_x <= $canvas_w) {
                ($anchor_global, $anchor_screen_x) = $self->_anchor_index_and_x($mouse_x);
            }
        }
        
        # Si no se pudo usar el mouse, usar la última vela real
        if (!defined $anchor_global) {
            my $last_real_idx = $self->{market_data}->last_index();
            my $anchor_idx = $end > $last_real_idx ? $last_real_idx : $end;
            $anchor_idx = 0 if $anchor_idx < 0;

            my $old_scale = Market::Panels::Scales->new(
                bars         => $old_visible,
                right_margin => RIGHT_MARGIN,
            );
            $old_scale->{width} = $self->_canvas_width($self->{price_canvas});

            my $local_anchor = $anchor_idx - $start;
            $anchor_screen_x = $old_scale->index_to_center_x($local_anchor);
            $anchor_global = $anchor_idx;
        }
    }

    # Aplicar el cambio de zoom manteniendo fijo el ancla
    $self->{visible_bars} = $new_visible;

    my $new_scale = Market::Panels::Scales->new(
        bars         => $new_visible,
        right_margin => RIGHT_MARGIN,
    );
    $new_scale->{width} = $self->_canvas_width($self->{price_canvas});

    my $local_target = $new_scale->x_to_index_float($anchor_screen_x) - 0.5;
    my $end_idx      = $anchor_global + ($new_visible - 1 - $local_target);
    my $new_offset   = ($total - 1) - $end_idx;

    $self->{offset} = $self->_clamp_offset($self->round($new_offset));

    $self->_clear_ctrl_zoom_state() unless defined $anchor_x;

    $self->request_render();
}

# _on_time_axis_motion: Maneja movimiento del ratón sobre el eje temporal
sub _on_time_axis_motion {
    my ($self, $widget, $x, $y) = @_;

    return unless defined $x;
    $self->{last_mouse_x} = $self->round($x);
    $self->{last_mouse_y} = undef;
    $self->{active_canvas} = $widget if defined $widget;
    $self->_draw_crosshair_all();
}

# _start_time_axis_drag: Inicia arrastre en el eje temporal (zoom horizontal)
sub _start_time_axis_drag {
    my ($self, $widget, $x, $y) = @_;

    my $root_x = eval { $widget->pointerx() };
    $self->{time_axis_drag_start_x} = defined $root_x ? $root_x : $x;
    $self->{time_axis_drag_visible} = $self->{visible_bars};
}

# _on_time_axis_drag: Maneja arrastre en el eje temporal 
sub _on_time_axis_drag {
    my ($self, $widget, $x, $y) = @_;

    $self->_on_time_axis_motion($widget, $x, $y);
    return unless defined $self->{time_axis_drag_start_x};

    my $root_x = eval { $widget->pointerx() };
    my $current_x = defined $root_x ? $root_x : $x;
    return unless defined $current_x;

    my $total = $self->{market_data}->size();
    return unless $total && $total > 0;

    my $max_visible = $total < MAX_VISIBLE_BARS ? $total : MAX_VISIBLE_BARS;
    my $delta = int(($current_x - $self->{time_axis_drag_start_x}) / TIME_AXIS_DRAG_PX_PER_BAR);
    my $new_visible = ($self->{time_axis_drag_visible} || $self->{visible_bars}) + $delta;
    $new_visible = MIN_VISIBLE_BARS if $new_visible < MIN_VISIBLE_BARS;
    $new_visible = $max_visible     if $new_visible > $max_visible;
    return if $new_visible == $self->{visible_bars};   

    $self->_horizontal_zoom($new_visible - $self->{visible_bars}, undef);
}


# _end_time_axis_drag: Limpia estado del arrastre en el eje temporal
sub _end_time_axis_drag {
    my ($self) = @_;
    $self->{time_axis_drag_start_x} = undef;
    $self->{time_axis_drag_visible} = undef;
}

# _apply_vertical_drag_from_start: Aplica arrastre vertical (pan Y) durante un drag
sub _apply_vertical_drag_from_start {
    my ($self, $current_y) = @_;

    return unless defined $current_y;
    return unless defined $self->{drag_start_y};
    return unless defined $self->{drag_start_min_y} && defined $self->{drag_start_max_y};

    my $range = $self->{drag_start_max_y} - $self->{drag_start_min_y};
    return if $range <= 0;

    my (undef, $height) = $self->_canvas_size($self->{price_canvas});
    return if $height <= 0;

    my $dy = $current_y - $self->{drag_start_y};
    return if $dy == 0;

    # Convertir píxeles movidos a cambio en valor financiero
    my $delta_value = $dy * ($range / $height);
    $self->{manual_min_y} = $self->{drag_start_min_y} + $delta_value;
    $self->{manual_max_y} = $self->{drag_start_max_y} + $delta_value;
    $self->{is_auto_scale} = 0;   # Cambiar a modo manual automáticamente
}

# _start_price_axis_drag: Inicia arrastre en el eje lateral de precios (zoom Y)
sub _start_price_axis_drag {
    my ($self, $widget, $y) = @_;

    my $root_y = eval { $widget->pointery() };
    $self->{axis_drag_start_y} = defined $root_y ? $root_y : $y;

    my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
    my $min = defined $self->{manual_min_y} ? $self->{manual_min_y} : (defined $scale ? $scale->{min_y} : undef);
    my $max = defined $self->{manual_max_y} ? $self->{manual_max_y} : (defined $scale ? $scale->{max_y} : undef);
    return unless defined $min && defined $max && $max > $min;

    $self->{axis_drag_min_y} = $min;
    $self->{axis_drag_max_y} = $max;
}

# _on_price_axis_drag: Maneja arrastre en el eje lateral (zoom Y exponencial)
sub _on_price_axis_drag {
    my ($self, $widget, $y) = @_;

    return unless defined $self->{axis_drag_start_y};
    return unless defined $self->{axis_drag_min_y} && defined $self->{axis_drag_max_y};

    my $root_y = eval { $widget->pointery() };
    my $current_y = defined $root_y ? $root_y : $y;
    return unless defined $current_y;

    my $dy = $current_y - $self->{axis_drag_start_y};
    my $min = $self->{axis_drag_min_y};
    my $max = $self->{axis_drag_max_y};
    my $center = ($min + $max) / 2;
    my $half = ($max - $min) / 2;
    my $factor = exp($dy / 220);
    $factor = 0.000001 if $factor < 0.000001;   # Evitar valores absurdos
    $half *= $factor;

    $self->{manual_min_y} = $center - $half;
    $self->{manual_max_y} = $center + $half;
    $self->{is_auto_scale} = 0;
    $self->request_render();
}

# _end_price_axis_drag: Limpia estado del arrastre en el eje lateral
sub _end_price_axis_drag {
    my ($self) = @_;
    $self->{axis_drag_start_y} = undef;
    $self->{axis_drag_min_y} = undef;
    $self->{axis_drag_max_y} = undef;
}

# _start_atr_axis_drag: Inicia arrastre en el eje lateral del ATR
sub _start_atr_axis_drag {
    my ($self, $widget, $y) = @_;
    
    my $root_y = eval { $widget->pointery() };
    $self->{atr_axis_drag_start_y} = defined $root_y ? $root_y : $y;
    
    my $scale = $self->{atr_panel} ? $self->{atr_panel}->{scale} : undef;
    
    my $min = defined $self->{atr_manual_min_y} 
        ? $self->{atr_manual_min_y} 
        : (defined $scale ? $scale->{min_y} : undef);
        
    my $max = defined $self->{atr_manual_max_y} 
        ? $self->{atr_manual_max_y} 
        : (defined $scale ? $scale->{max_y} : undef);
    
    return unless defined $min && defined $max && $max > $min;
    
    $self->{atr_axis_drag_min_y} = $min;
    $self->{atr_axis_drag_max_y} = $max;
}

# _on_atr_axis_drag: Maneja arrastre en el eje lateral del ATR (zoom exponencial)
sub _on_atr_axis_drag {
    my ($self, $widget, $y) = @_;
    
    return unless defined $self->{atr_axis_drag_start_y};
    return unless defined $self->{atr_axis_drag_min_y} && defined $self->{atr_axis_drag_max_y};
    
    my $root_y = eval { $widget->pointery() };
    my $current_y = defined $root_y ? $root_y : $y;
    return unless defined $current_y;
    
    my $dy = $current_y - $self->{atr_axis_drag_start_y};
    my $min = $self->{atr_axis_drag_min_y};
    my $max = $self->{atr_axis_drag_max_y};
    my $center = ($min + $max) / 2;
    my $half = ($max - $min) / 2;
    
    my $factor = exp($dy / 220);
    $factor = 0.000001 if $factor < 0.000001;
    $half *= $factor;
    
    $self->{atr_manual_min_y} = $center - $half;
    $self->{atr_manual_max_y} = $center + $half;
    $self->{atr_is_auto_scale} = 0;
    
    $self->request_render();
}

# _end_atr_axis_drag: Limpia estado del arrastre en el eje lateral del ATR
sub _end_atr_axis_drag {
    my ($self) = @_;
    
    $self->{atr_axis_drag_start_y} = undef;
    $self->{atr_axis_drag_min_y}   = undef;
    $self->{atr_axis_drag_max_y}   = undef;
}

# set_scale_mode: Cambia entre escala automática y manual
sub set_scale_mode {
    my ($self, $mode) = @_;

    return unless defined $mode && ($mode eq 'auto' || $mode eq 'manual');

    if ($mode eq 'auto') {
        $self->{is_auto_scale} = 1;
        $self->{manual_min_y} = undef;
        $self->{manual_max_y} = undef;
    } else {
        $self->{is_auto_scale} = 0;
    }

    $self->request_render();
}

# set_chart_mode: Cambia entre modo automático y manual
sub set_chart_mode {
    my ($self, $mode) = @_;

    return unless defined $mode && ($mode eq 'automatic' || $mode eq 'manual');

    $self->{chart_mode} = $mode;

    if ($mode eq 'automatic') {
        # Modo automático: forzar escala Y automática
        $self->{is_auto_scale} = 1;
        $self->{manual_min_y} = undef;
        $self->{manual_max_y} = undef;
    } else {
    }

    $self->request_render();
}

# _on_resize: Maneja redimensionamiento de la ventana
sub _on_resize {
    my ($self, $widget) = @_;

    return if $self->{_resize_pending};   # Ya hay un resize programado
    $self->{_resize_pending} = 1;
    my $canvas = $self->{price_canvas} || $widget;
    if ($canvas) {
        $canvas->after(60, sub {
            $self->{_resize_pending} = 0;
            $self->request_render();
        });
        return;
    }
    $self->{_resize_pending} = 0;
    $self->request_render();
}

# _end_drag: Limpia el estado después de un arrastre
sub _end_drag {
    my ($self) = @_;

    if (defined $self->{drag_cursor_canvas}) {
        eval { $self->{drag_cursor_canvas}->configure(-cursor => 'crosshair') };
    }
    $self->{drag_start_x} = undef;
    $self->{drag_start_y} = undef;
    $self->{drag_start_min_y} = undef;
    $self->{drag_start_max_y} = undef;
    $self->{drag_cursor_canvas} = undef;
}

# _vertical_drag: Desplazamiento vertical (pan Y) con teclas Up/Down
sub _vertical_drag {
    my ($self, $dy) = @_;

    return if $self->{is_auto_scale};   # Solo funciona en modo manual
    return if !$dy || $dy == 0;

    my $price_scale = $self->{price_panel}->{scale};
    return if !defined $price_scale;

    # Calcular cuánto vale un píxel en unidades financieras
    my $val_at_zero = $price_scale->y_to_value(0);
    my $val_at_one  = $price_scale->y_to_value(1);
    my $units_per_pixel = $val_at_zero - $val_at_one;

    my $value_delta = $dy * $units_per_pixel;

    $self->{manual_min_y} += $value_delta;
    $self->{manual_max_y} += $value_delta;

    $self->request_render();
}

# _vertical_zoom: Zoom Y con teclas '+' y '-'
sub _vertical_zoom {
    my ($self, $factor) = @_;

    return if $self->{is_auto_scale};
    return if !$factor || $factor <= 0;

    my $min = $self->{manual_min_y};
    my $max = $self->{manual_max_y};
    return if !defined $min || !defined $max;

    my $center = ($min + $max) / 2;
    my $half_range = ($max - $min) / 2;

    $half_range *= $factor;   # factor < 1 = zoom in, factor > 1 = zoom out

    $self->{manual_min_y} = $center - $half_range;
    $self->{manual_max_y} = $center + $half_range;

    $self->request_render();
}

# _on_mouse_move: Maneja movimiento del ratón sobre cualquier canvas
sub _on_mouse_move {
    my ($self, $widget, $raw_x, $raw_y) = @_;
    
    return if !defined $raw_x || !defined $raw_y;
    
    my $pixel_x = $self->round($raw_x);
    my $pixel_y = $self->round($raw_y);
    
    $self->{last_mouse_x} = $pixel_x;
    $self->{last_mouse_y} = $pixel_y;
    $self->{active_canvas} = $widget;
    
    $self->_draw_crosshair_all();
}

# _crosshair_time_label: Genera etiqueta de tiempo para el crosshair (HH:MM o fecha completa)
sub _crosshair_time_label {
    my ($self) = @_;

    my $last_x = $self->{last_mouse_x};
    return undef unless defined $last_x;   # Sin cursor → sin etiqueta

    # Ventana visible
    my ($start, $end) = $self->compute_window();
    my $bars = $end - $start + 1;
    return undef if $bars < 1;

    # Escala para convertir X a índice
    my $scale = Market::Panels::Scales->new(
        bars         => $bars,
        right_margin => RIGHT_MARGIN,
    );
    $scale->{width} = $self->_canvas_width($self->{price_canvas});

    # X → índice LOCAL → índice GLOBAL
    my $local  = $scale->x_to_index($last_x);
    my $global = $start + $local;

    # Validar que el índice esté dentro del rango real de datos
    my $size = $self->{market_data}->size();
    return undef if $global < 0 || $global >= $size;

    # Obtener timestamp y parsear
    my $ts = $self->{market_data}->get_timestamp($global);
    return undef unless defined $ts;
    my $tm = eval { Time::Moment->from_string($ts) };
    return undef unless $tm;

    # Devolver formato completo (fecha + hora)
    return $self->_format_full_datetime($tm, 0);
}

# _format_full_datetime: Formatea fecha completa para el crosshair
sub _format_full_datetime {
    my ($self, $tm, $is_day_change) = @_;

    return undef unless defined $tm && ref($tm) eq 'Time::Moment';

    # Días de la semana en español (abreviado) - domingo = 0
    my @days = qw(dom lun mar mié jue vie sáb);
    # Meses en español (abreviado)
    my @months = qw(ene feb mar abr may jun jul ago sep oct nov dic);

    my $day_name = $days[$tm->day_of_week];
    my $day_num  = $tm->day_of_month;
    my $month    = $months[$tm->month - 1];
    my $year     = $tm->year;
    my $year_short = substr($year, -2);  # '26 en lugar de 2026

    # Parte de la fecha: "lun 29 Sep '26"
    my $date_part = sprintf("%s %d %s '%02d", $day_name, $day_num, $month, $year_short);

    # Si no, agregar la hora: "lun 29 Sep '26 20:36"
    my $hour   = sprintf("%02d", $tm->hour);
    my $minute = sprintf("%02d", $tm->minute);
    return "$date_part $hour:$minute";
}

# _draw_crosshair_all: Dibuja el crosshair en todos los paneles y ejes
sub _draw_crosshair_all {
    my ($self) = @_;

    my $last_x = $self->{last_mouse_x};
    my $last_y = $self->{last_mouse_y};

    if (!defined $last_x) {
        # Cursor fuera: limpiar todo
        $self->{price_panel}->draw_crosshair(undef, undef, undef);
        $self->{atr_panel}->draw_crosshair(undef, undef);
        $self->_draw_price_axis_crosshair(undef);
        $self->_draw_atr_axis_crosshair(undef);
        return;
    }

    # Determinar qué panel está activo para mostrar la línea Y
    my $price_y = undef;
    my $atr_y = undef;

    if (defined $self->{active_canvas} && defined $self->{time_axis_canvas} && $self->{active_canvas} == $self->{time_axis_canvas}) {
        # Eje temporal: solo línea vertical
        $price_y = undef;
        $atr_y = undef;
    } elsif (defined $self->{active_canvas} && $self->{active_canvas} == $self->{atr_canvas}) {
        # Panel ATR activo: mostrar línea Y en el panel ATR
        $atr_y = $last_y;
    } else {
        # Panel de precios activo (o cualquier otro): mostrar línea Y en precios
        $price_y = $last_y;
    }

    # Etiqueta de tiempo con formato completo (fecha + hora)
    my $time_text = $self->_crosshair_time_label();

    # Dibujar en cada panel
    $self->{price_panel}->draw_crosshair($last_x, $price_y, $time_text);
    $self->{atr_panel}->draw_crosshair($last_x, $atr_y);
    $self->_draw_price_axis_crosshair($price_y);
    $self->_draw_atr_axis_crosshair($atr_y);
}

# set_timeframe: Cambia la temporalidad (1m, 5m, 15m)
sub set_timeframe {
    my ($self, $tf) = @_;

    if ($tf ne '1m' && $tf ne '5m' && $tf ne '15m') {
        warn "Temporalidad '$tf' no soportada del sistema.";
        return;
    }

    # Reconstruir velas para la nueva temporalidad (si no es 1m)
    $self->{market_data}->build_tf_candles($tf) if $tf ne '1m';
    $self->{market_data}->set_timeframe($tf);
    
    # Resetear indicadores y recalcular desde cero
    $self->{indicator_manager}->reset_all();
    for (my $i = 0; $i < $self->{market_data}->size(); $i++) {
        $self->{indicator_manager}->update_last($self->{market_data}, $i);
    }
    
    # Resetear vista
    $self->{is_auto_scale} = 1;
    $self->{manual_min_y} = undef;
    $self->{manual_max_y} = undef;
    $self->reset_view();
}

# reset_view: Restablece la vista a los valores por defecto
sub reset_view {
    my ($self) = @_;

    $self->{visible_bars} = 60;   # Zoom por defecto
    $self->{offset} = 0;          # Scroll a la derecha (velas más recientes)
    $self->{is_auto_scale} = 1;   # Escala automática
    $self->{manual_min_y} = undef;
    $self->{manual_max_y} = undef;
    $self->_clear_ctrl_zoom_state();
    $self->request_render();
}


# compute_intraday_labels: Genera etiquetas del eje temporal inferior
sub compute_intraday_labels {
    my ($self) = @_;

    my @labels;

    # Obtener timestamps de todas las velas visibles (ya parseados a Time::Moment)
    my $visible_elements = $self->get_all_timestamps();
    my $total = scalar(@$visible_elements);
    return \@labels if $total == 0;

    # Ventana visible en índices GLOBALES
    my ($start, $end) = $self->compute_window();
    my $bars = $end - $start + 1;
    $bars = 1 if $bars < 1;

    # Escala para medir separación en píxeles
    my $scale = Market::Panels::Scales->new(
        bars         => $bars,
        right_margin => RIGHT_MARGIN,
    );
    $scale->{width} = $self->_canvas_width($self->{price_canvas});

    # Identificar cambios de día dentro de la ventana visible
    my %is_date_local;
    my $anchors = $self->{market_data}->compute_time_anchors();
    for my $a (@$anchors) {
        next unless $a->{is_date};
        my $g = $a->{index};
        next if $g < $start || $g > $end;
        $is_date_local{ $g - $start } = 1;
    }
    my @date_locals = sort { $a <=> $b } keys %is_date_local;

    # Mapa índice LOCAL → Time::Moment
    my %tm_by_local;
    for my $el (@$visible_elements) {
        $tm_by_local{ $el->{index} - $start } = $el->{ts};
    }

    # Selección con espaciado dinámico >= 40 píxeles
    my $step = 1;
    my @chosen;
    while (1) {
        my %set;
        # Etiquetas regulares: índices globales divisibles por step
        for my $el (@$visible_elements) {
            my $global = $el->{index};
            next if $global % $step != 0;
            $set{$global - $start} = 1;
        }
        # Forzar inclusión de cambios de día
        $set{$_} = 1 for @date_locals;

        my @idxs = sort { $a <=> $b } keys %set;

        # Verificar separación mínima de 40 píxeles
        my $ok = 1;
        for (my $j = 1; $j < @idxs; $j++) {
            my $dx = $scale->index_to_center_x($idxs[$j])
                   - $scale->index_to_center_x($idxs[$j - 1]);
            if ($dx < 40) { $ok = 0; last; }
        }

        if ($ok || $step >= $bars) {
            @chosen = @idxs;
            last;
        }
        $step++;
    }

    # Construir etiquetas
    for my $local (@chosen) {
        my $tm = $tm_by_local{$local};
        next unless defined $tm;
        my $is_date = $is_date_local{$local} ? 1 : 0;
        my $text = $self->_time_label_for_index($tm, $is_date);
        next unless defined $text;
        push @labels, { index => $local, text => $text, is_date => $is_date };
    }

    return \@labels;
}

# _time_label_for_index: Formatea un Time::Moment como 'HH:MM' o 'DD Mon'
sub _time_label_for_index {
    my ($self, $tm, $is_date) = @_;

    return undef unless defined $tm && ref($tm) eq 'Time::Moment';

    if ($is_date) {
        my @days   = qw(dom lun mar mié jue vie sáb);
        my @months = qw(ene feb mar abr may jun jul ago sep oct nov dic);
        my $day_name = $days[$tm->day_of_week];
        my $day_num  = $tm->day_of_month;
        my $month    = $months[$tm->month - 1];
        return undef unless defined $day_name && defined $day_num && defined $month;
        return sprintf("%s %d %s", $day_name, $day_num, $month);
    }

    return sprintf("%02d:%02d", $tm->hour, $tm->minute);
}

# get_all_timestamps: Obtiene timestamps de todas las velas visibles 
sub get_all_timestamps {
    my ($self) = @_;

    my ($start, $end) = $self->compute_window();
    my @timestamps;
    my $last_index = eval { $self->{market_data}->last_index() };
    $last_index = ($self->{market_data}->size() || 0) - 1 if !defined $last_index;
    my $last_ts = $last_index >= 0 ? $self->{market_data}->get_timestamp($last_index) : undef;
    my $last_tm = defined $last_ts ? eval { Time::Moment->from_string($last_ts) } : undef;
    my $tf_minutes = $self->_timeframe_minutes();

    for (my $i = $start; $i <= $end; $i++) {
        my $ts = ($i >= 0 && $i <= $last_index) ? $self->{market_data}->get_timestamp($i) : undef;
        if (defined $ts) {
            my $parsed = eval { Time::Moment->from_string($ts) };
            push @timestamps, { index => $i, ts => $parsed } if $parsed;
        }
        elsif (defined $last_tm && $i > $last_index) {
            # Extrapolar para velas futuras
            my $future = eval { $last_tm->plus_minutes(($i - $last_index) * $tf_minutes) };
            push @timestamps, { index => $i, ts => $future } if $future;
        }
    }

    return \@timestamps;
}

# ============================================================================
# MÉTODOS PÚBLICOS DE NAVEGACIÓN
# ============================================================================

# go_to_start: Navega al inicio del gráfico (primeras velas)
sub go_to_start {
    my ($self) = @_;
    
    my $total = $self->{market_data}->size();
    return unless $total > 0;
    
    $self->{offset} = 0;
    $self->request_render();
    
    # Opcional: registrar en log
    # warn "[ChartEngine] Navegando al inicio\n";
}

# go_to_end: Navega al final del gráfico (últimas velas)
sub go_to_end {
    my ($self) = @_;
    
    my $total = $self->{market_data}->size();
    return unless $total > 0;
    
    my $max_offset = $self->_max_offset_for_visible();
    $self->{offset} = $max_offset;
    $self->request_render();
    
    # Opcional: registrar en log
    # warn "[ChartEngine] Navegando al final (offset=$max_offset)\n";
}

# get_current_offset: Devuelve el offset actual (para depuración)
sub get_current_offset {
    my ($self) = @_;
    return $self->{offset};
}

# get_max_offset: Devuelve el offset máximo permitido (público)
sub get_max_offset {
    my ($self) = @_;
    return $self->_max_offset_for_visible();
}

# _timeframe_minutes: Devuelve la duración en minutos del timeframe actual
sub _timeframe_minutes {
    my ($self) = @_;

    my $tf = eval { $self->{market_data}->{active_tf} } || '1m';
    return 5  if $tf eq '5m';
    return 15 if $tf eq '15m';
    return 1;   
}

1;