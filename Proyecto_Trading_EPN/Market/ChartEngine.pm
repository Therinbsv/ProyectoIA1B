package Market::ChartEngine;  # Declara el paquete/namespace del módulo
use strict;                   # Obliga a declarar variables con 'my' (buena práctica)
use warnings;                 # Muestra advertencias para evitar errores comunes

use Time::Moment;             # Módulo para manejar fechas/horas de forma robusta
use Market::Panels::Scales;   # Nuestro sistema de coordenadas (datos ↔ píxeles)
use Market::Panels::PricePanel;   # Panel que dibuja las velas japonesas
use Market::Panels::ATRPanel;     # Panel que dibuja la línea del ATR


use constant {
    RIGHT_MARGIN     => 0,       # Margen derecho del área de ploteo (0 porque hay canvas separados)
    MIN_VISIBLE_BARS => 2,       # Mínimo de velas visibles (Req. 8, 10)
    MAX_VISIBLE_BARS => 300,     # Máximo de velas visibles
    ZOOM_STEP        => 5,       # Barras por paso de rueda en zoom horizontal
    CTRL_MASK        => 0x0004,  # Máscara para detectar Ctrl presionado (X11)
    TIME_AXIS_DRAG_PX_PER_BAR => 8,  # Píxeles por barra en arrastre del eje temporal
};

# ============================================================================
# _default_theme: Paleta de tema claro por defecto
# ============================================================================

sub _default_theme {
    return {
        bg             => '#ffffff',   # Fondo blanco
        grid           => '#e6e6e6',   # Líneas de grid gris muy claro
        date_grid      => '#c4c9d1',   # Líneas de cambio de día gris suave
        axis_text      => '#363a45',   # Texto de ejes gris oscuro
        bull           => '#26a69a',   # Verde para velas alcistas
        bear           => '#ef5350',   # Rojo para velas bajistas
        atr_line       => '#2962ff',   # Azul para la línea ATR
        crosshair_line => '#9598a1',   # Gris para el crosshair
        label_bg       => '#363a45',   # Fondo oscuro para etiquetas
        label_fg       => '#ffffff',   # Texto blanco en etiquetas
        last_price_bg  => '#363a45',   # Fondo del último precio (por defecto oscuro)
        last_price_fg  => '#ffffff',   # Texto del último precio (blanco)
    };
}

# ============================================================================
# new(): Constructor de ChartEngine
# ============================================================================
sub new {
    my ($class, %args) = @_;   # $class es 'Market::ChartEngine', %args son los parámetros named

    # Creamos el objeto como un hashref con valores por defecto
    my $self = {
        # Datos e indicadores (inyectados desde fuera)
        market_data      => $args{market_data},       # Objeto con los precios
        indicator_manager=> $args{indicator_manager}, # Contenedor de indicadores
        price_canvas     => $args{price_canvas},      # Canvas para velas
        atr_canvas       => $args{atr_canvas},        # Canvas para ATR
        
        # Estado del zoom/scroll horizontal
        visible_bars     => 60,    # Cuántas velas se ven inicialmente (zoom por defecto)
        offset           => 0,     # Desplazamiento desde la derecha (0 = mostrar las más recientes)
        
        # Escala del eje Y (precios)
        is_auto_scale    => 1,     # 1 = escala automática, 0 = escala manual
        manual_min_y     => undef, # Mínimo Y en modo manual (si is_auto_scale=0)
        manual_max_y     => undef, # Máximo Y en modo manual
        
        # Control de render diferido (coalescing)
        render_pending   => 0,     # Flag: 1 si ya hay un render programado
        
        # Estado para arrastre horizontal (scroll con botón izquierdo)
        drag_start_x     => undef, # X inicial del arrastre (en píxeles)
        drag_start_y     => undef, # Y inicial del arrastre
        drag_start_offset=> 0,     # Offset al comenzar el arrastre
        
        # Estado para arrastre del eje Y (zoom vertical manual)
        axis_drag_start_y=> undef, # Y inicial del arrastre en el eje lateral
        axis_drag_min_y  => undef, # Mínimo Y al comenzar el arrastre
        axis_drag_max_y  => undef, # Máximo Y al comenzar el arrastre
        
        vertical_drag_y  => undef, # (Parece no usarse, quizás legacy)
        
        # Sobrescribir con cualquier argumento adicional que haya llegado
        %args,
    };
    bless $self, $class;   # "Bendecir" el hashref como objeto de la clase

    # Tema claro: si nos dieron un theme lo usamos, si no, usamos el default
    # El tema viaja dentro de la instancia, nunca como variable global.
    $self->{theme} = $args{theme} || _default_theme();

    # Crear el panel de precios (inyectando canvas y tema)
    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas => $self->{price_canvas},
        theme  => $self->{theme},
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

# ============================================================================
# compute_window: Calcula los índices GLOBALES de inicio y fin de la ventana visible
# ============================================================================
sub compute_window {
    my ($self) = @_;
    
    # Obtener cuántas velas hay en total en MarketData
    my $total_candles = $self->{market_data}->size();
    
    # Si no hay datos, devolver (0, -1) que indica ventana vacía
    return (0, -1) if !$total_candles || $total_candles <= 0;

    # Ajustar visible_bars si es menor que el mínimo permitido
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
    # offset=0 → última vela real; offset=1 → penúltima, etc.
    my $end_idx = $total_candles - 1 - $self->{offset};
    
    # Calcular el índice de la primera vela visible (más a la izquierda)
    my $start_idx = $end_idx - $self->{visible_bars} + 1;

    return ($start_idx, $end_idx);
}

# ============================================================================
# round: Redondea al entero más cercano (funciona con números positivos y negativos)
# ============================================================================
sub round {
    my ($self, $value) = @_;

    return 0 if !defined $value;   # Si no hay valor, devolver 0

    # Redondeo al entero más cercano: sumar 0.5 para positivos, restar 0.5 para negativos
    return int($value + ($value >= 0 ? 0.5 : -0.5));
}

# ============================================================================
# _max_offset_for_visible: Máximo offset permitido (scroll hacia la izquierda)
# ============================================================================
sub _max_offset_for_visible {
    my ($self) = @_;

    my $total = $self->{market_data}->size() || 0;
    return 0 if $total < MIN_VISIBLE_BARS;   # Si hay muy pocas velas, offset máximo = 0

    # El máximo offset es total - MIN_VISIBLE_BARS, pero no puede ser negativo
    return ($total - MIN_VISIBLE_BARS) > 0 ? ($total - MIN_VISIBLE_BARS) : 0;
}

# ============================================================================
# _min_offset_for_visible: Mínimo offset permitido (scroll hacia la derecha)
# ============================================================================
sub _min_offset_for_visible {
    my ($self) = @_;

    my $total = $self->{market_data}->size() || 0;
    return 0 if $total < MIN_VISIBLE_BARS;   # Si hay pocas velas, offset mínimo = 0

    # visible_bars no puede ser menor que MIN_VISIBLE_BARS
    my $visible = $self->{visible_bars} || MIN_VISIBLE_BARS;
    $visible = $total if $visible > $total;   # No puede superar el total

    # Si visible > MIN_VISIBLE_BARS, el offset mínimo es negativo
    # Representa cuántas velas "futuras" podemos mostrar a la izquierda
    return -(($visible > MIN_VISIBLE_BARS) ? ($visible - MIN_VISIBLE_BARS) : 0);
}

# ============================================================================
# _clamp_offset: Acota el offset dentro de los límites permitidos
# ============================================================================
sub _clamp_offset {
    my ($self, $offset) = @_;

    $offset = 0 if !defined $offset;                    # Si no hay offset, usar 0
    my $min_offset = $self->_min_offset_for_visible();  # Mínimo permitido (puede ser negativo)
    my $max_offset = $self->_max_offset_for_visible();  # Máximo permitido (positivo)
    $offset = $min_offset if $offset < $min_offset;     # No bajar del mínimo
    $offset = $max_offset if $offset > $max_offset;     # No superar el máximo
    return $offset;
}

# ============================================================================
# _pad_visible_slice: Rellena un slice con 'undef' para que tenga el tamaño exacto
# ============================================================================
sub _pad_visible_slice {
    my ($self, $slice, $start, $end) = @_;

    return unless $slice;   # Si no hay slice, no hacer nada
    # Calcular cuántos elementos debería tener
    my $target = defined $start && defined $end && $end >= $start ? $end - $start + 1 : 0;
    # Si el slice actual es más corto, añadir undef hasta alcanzar el tamaño deseado
    push @$slice, (undef) x ($target - @$slice) if $target > @$slice;
}

# ============================================================================
# _canvas_width: Obtiene el ancho de un canvas Tk de forma robusta
# ============================================================================
sub _canvas_width {
    my ($self, $canvas) = @_;
    return 1 unless $canvas;   # Si no hay canvas, devolver 1

    my $w = 0;
    # Intentar obtener geometría con geometry()
    my $geom = eval { $canvas->geometry() };
    if (defined $geom && $geom =~ /^(\d+)x\d+/) {
        $w = $1;   # Extraer el ancho (primer número antes de la 'x')
    }
    # Si falló, probar con Width() o width()
    $w ||= eval { $canvas->Width() } || eval { $canvas->width() } || 1;
    return $w > 1 ? $w : 1;   # Asegurar que sea al menos 1
}

# ============================================================================
# _canvas_size: Obtiene ancho y alto de un canvas Tk
# ============================================================================
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

# ============================================================================
# _reset_canvas_view: Reinicia la vista de un canvas (scrollregion, etc.)
# ============================================================================
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

# ============================================================================
# request_render: Programa un render diferido (coalescing)
# ============================================================================
sub request_render {
    my ($self) = @_;

    # Si ya hay un render pendiente, no programar otro
    return if $self->{render_pending};
    $self->{render_pending} = 1;   # Marcar que hay un render programado

    # Elegir un canvas para programar el 'after' (timer)
    my $canvas = $self->{price_canvas} || $self->{atr_canvas};
    if ($canvas) {
        # Programar render después de 20 milisegundos
        $canvas->after(20, sub {
            $self->{render_pending} = 0;   # Limpiar flag
            $self->render();               # Ejecutar render
        });
    } else {
        # Si no hay canvas, renderizar inmediatamente (caso de pruebas)
        $self->{render_pending} = 0;
        $self->render();
    }
}

# ============================================================================
# render: MÉTODO PRINCIPAL de dibujo (el corazón del motor gráfico)
# ============================================================================
sub render {
    my ($self) = @_;
    
    # 1. Obtener la porción temporal de la ventana visible
    my ($start, $end) = $self->compute_window();
    
    # 2. Extraer subconjuntos de datos reales (solo las velas visibles)
    my $visible_candles = $self->{market_data}->get_slice($start, $end);
    my $visible_atr     = $self->{indicator_manager}->slice_array('ATR', $start, $end);
    
    # Asegurar que los slices tengan el tamaño correcto (rellenar con undef si falta)
    $self->_pad_visible_slice($visible_candles, $start, $end);
    $self->_pad_visible_slice($visible_atr, $start, $end);
    
    # 3. Calcular rangos de precios e indicadores para construir escalas dinámicas
    #    price_panel->get_y_range devuelve (min_precio, max_precio) con padding del 2%
    #    atr_panel->get_y_range devuelve (min_atr, max_atr) con padding del 5%
    my ($min_p, $max_p) = $self->{price_panel}->get_y_range($visible_candles);
    my ($min_a, $max_a) = $self->{atr_panel}->get_y_range($visible_atr);
    
    # Si estamos en modo manual (is_auto_scale=0), usar los valores manuales
    if (!$self->{is_auto_scale} && defined $self->{manual_min_y} && defined $self->{manual_max_y}) {
        ($min_p, $max_p) = ($self->{manual_min_y}, $self->{manual_max_y});
    } else {
        # En modo automático, guardamos los rangos calculados por si cambiamos a manual
        ($self->{manual_min_y}, $self->{manual_max_y}) = ($min_p, $max_p);
    }

    # Rangos por defecto si hay problemas (ej: sin datos o rango cero)
    if (!defined $min_p || !defined $max_p || $min_p == $max_p) {
        $min_p = 20000;   # Valor típico para Bitcoin
        $max_p = 30000;
    }
    if (!defined $min_a || !defined $max_a || $min_a == $max_a) {
        $min_a = 0;       # ATR mínimo por defecto
        $max_a = 100;     # ATR máximo por defecto
    }
    
    # 4. Instanciar los sistemas de coordenadas (Scales)
    #    La escala X usa un ancho compartido para que PricePanel y ATRPanel
    #    queden sincronizados barra por barra.
    my ($price_w, $price_h) = $self->_canvas_size($self->{price_canvas});
    my ($atr_w, $atr_h)     = $self->_canvas_size($self->{atr_canvas});
    my $shared_w = $price_w;   # Ambos paneles usan el mismo ancho para el eje X

    # Resetear las vistas de los canvases (evitar scroll regions mal configuradas)
    $self->_reset_canvas_view($self->{price_canvas});
    $self->_reset_canvas_view($self->{atr_canvas});
    $self->_reset_canvas_view($self->{price_axis_canvas});
    $self->_reset_canvas_view($self->{atr_axis_canvas});
    $self->_reset_canvas_view($self->{time_axis_canvas});

    # Mensaje de diagnóstico (solo la primera vez)
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
    $atr_scale->{draw_labels} = $self->{atr_axis_canvas} ? 0 : 1;
    $atr_scale->{draw_last_label} = $self->{atr_axis_canvas} ? 0 : 1;
    
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

# ============================================================================
# _render_price_axis: Dibuja el eje Y lateral del panel de precios
# ============================================================================
sub _render_price_axis {
    my ($self, $source_scale, $visible_candles) = @_;

    my $canvas = $self->{price_axis_canvas};
    return unless $canvas && $source_scale;   # Si no hay canvas o escala, salir

    my ($w, $h) = $self->_canvas_size($canvas);
    $canvas->delete('y_scale');           # Borrar etiquetas anteriores
    $canvas->delete('axis_last_price');   # Borrar etiqueta del último precio

    # Crear una escala para el eje Y (solo una barra, porque es solo para valores)
    my $axis_scale = Market::Panels::Scales->new(
        min_y        => $source_scale->{min_y},
        max_y        => $source_scale->{max_y},
        bars         => 1,               # Solo una barra (no necesitamos coordenadas X)
        right_margin => 0,
    );
    $axis_scale->{width}           = $w;
    $axis_scale->{height}          = $source_scale->{height} || $h;
    $axis_scale->{draw_grid}       = 0;   # No dibujar líneas de grid en el eje lateral
    $axis_scale->{draw_labels}     = 1;   # Sí dibujar etiquetas numéricas
    $axis_scale->{label_x}         = 4;   # Posición X para el texto (4 píxeles desde la izquierda)
    $axis_scale->{label_anchor}    = 'w'; # Anclaje 'w' = oeste (izquierda)
    $axis_scale->{grid_color}      = $self->{theme}{grid}      // '#e6e6e6';
    $axis_scale->{axis_text_color} = $self->{theme}{axis_text} // '#363a45';
    $axis_scale->_draw_y_scale($canvas);   # Dibujar el eje Y

    # Encontrar la última vela definida (para mostrar su precio de cierre)
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
        ? ($self->{theme}{bull} // '#26a69a')
        : ($self->{theme}{bear} // '#ef5350');
    my $fg = $self->{theme}{last_price_fg} // '#ffffff';

    # Dibujar rectángulo de fondo y texto del último precio
    $canvas->createRectangle(0, $y - 8, $w, $y + 8, -fill => $bg, -outline => $bg, -tags => 'axis_last_price');
    $canvas->createText(4, $y, -text => $label, -anchor => 'w', -font => 'Helvetica 9 bold', -fill => $fg, -tags => 'axis_last_price');
}

# ============================================================================
# _draw_price_axis_crosshair: Dibuja el crosshair en el eje lateral de precios
# ============================================================================
sub _draw_price_axis_crosshair {
    my ($self, $y) = @_;

    my $canvas = $self->{price_axis_canvas};
    return unless $canvas;

    $canvas->delete('axis_crosshair');   # Borrar crosshair anterior
    return unless defined $y;             # Si no hay Y, no dibujar

    my $scale = $self->{price_panel} ? $self->{price_panel}->{scale} : undef;
    return unless $scale;

    my ($w, undef) = $self->_canvas_size($canvas);
    my $value = $scale->y_to_value($y);   # Convertir Y a precio
    my $label = sprintf('%.2f', $value);
    my $bg = $self->{theme}{label_bg} // '#363a45';
    my $fg = $self->{theme}{label_fg} // '#ffffff';

    # Dibujar rectángulo y texto en el eje lateral
    $canvas->createRectangle(0, $y - 8, $w, $y + 8, -fill => $bg, -outline => $bg, -tags => 'axis_crosshair');
    $canvas->createText(4, $y, -text => $label, -anchor => 'w', -font => 'Helvetica 9 bold', -fill => $fg, -tags => 'axis_crosshair');
}

# ============================================================================
# _draw_atr_axis_crosshair: Dibuja el crosshair en el eje lateral del ATR
# ============================================================================
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
    my $bg = $self->{theme}{label_bg} // '#363a45';
    my $fg = $self->{theme}{label_fg} // '#ffffff';

    $canvas->createRectangle(0, $y - 8, $w, $y + 8, -fill => $bg, -outline => $bg, -tags => 'atr_axis_crosshair');
    $canvas->createText(4, $y, -text => $label, -anchor => 'w', -font => 'Helvetica 9 bold', -fill => $fg, -tags => 'atr_axis_crosshair');
}

# ============================================================================
# _render_time_axis: Dibuja el eje temporal inferior (con etiquetas de tiempo)
# ============================================================================
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

# ============================================================================
# _render_atr_axis: Dibuja el eje Y lateral del panel ATR
# ============================================================================
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
    $axis_scale->{grid_color}      = $self->{theme}{grid}      // '#e6e6e6';
    $axis_scale->{axis_text_color} = $self->{theme}{axis_text} // '#363a45';
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

# ============================================================================
# _bind_all_canvas: Conecta TODOS los eventos de Tk a los canvases
# ============================================================================
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
        
        # Teclas para control de escala Y
        $p_canvas->Tk::bind('<Key-a>', sub { $self->set_scale_mode('auto'); });   # 'a' → auto escala
        $p_canvas->Tk::bind('<Key-m>', sub { $self->set_scale_mode('manual'); });  # 'm' → manual
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
    
    # 2. Binding idéntico para el panel del ATR (misma lógica)
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

# ============================================================================
# bind_events: Punto de entrada para conectar eventos (llama a _bind_all_canvas)
# ============================================================================
sub bind_events {
    my ($self) = @_;
    $self->_bind_all_canvas();
}

# ============================================================================
# _anchor_index_and_x: Calcula el punto de anclaje para zoom con anclaje
# ============================================================================
sub _anchor_index_and_x {
    my ($self, $anchor_x) = @_;

    my ($start, $end) = $self->compute_window();
    my $bars = $end - $start + 1;
    $bars = 1 if $bars < 1;

    # Escala temporal para convertir X <-> índice
    my $scale = Market::Panels::Scales->new(
        bars         => $bars,
        right_margin => RIGHT_MARGIN,
    );
    $scale->{width} = $self->_canvas_width($self->{price_canvas});

    if (defined $anchor_x) {
        # Caso 1: cursor sobre una barra
        my $local  = $scale->x_to_index($anchor_x);   # Índice local (0..bars-1)
        my $global = $start + $local;                 # Índice global
        return ($global, $anchor_x);                  # La X se conserva
    }

    # Caso 2: sin cursor, anclar en la última vela visible
    my $last_real = ($self->{market_data}->size() || 1) - 1;
    my $anchor_index = $end > $last_real ? $last_real : $end;   # No anclar en velas futuras
    $anchor_index = 0 if $anchor_index < 0;
    my $local_of_anchor = $anchor_index - $start;
    my $screen_x = $scale->index_to_center_x($local_of_anchor);
    return ($anchor_index, $screen_x);
}

# ============================================================================
# _zoom_anchor_x: Decide si usar anclaje de cursor o no
# ============================================================================
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

    # Si el cursor está dentro del área de ploteo, devolver su X; si no, undef
    return ($x >= 0 && $x <= $plot_w) ? $x : undef;
}

# ============================================================================
# _wheel_zoom: Maneja el evento de la rueda del ratón
# ============================================================================
sub _wheel_zoom {
    my ($self, $widget, $step, $x, $y, $state) = @_;

    # Guardar posición del cursor para el crosshair
    if (defined $x) {
        $self->{last_mouse_x} = $self->round($x);
        $self->{last_mouse_y} = $self->round($y) if defined $y;
        $self->{active_canvas} = $widget if defined $widget;
    }

    # Verificar si Ctrl está presionado (máscara 0x0004)
    my $ctrl_pressed = defined $state && ($state & CTRL_MASK);
    # Si Ctrl está presionado, obtener X de anclaje; si no, undef
    my $anchor_x = $ctrl_pressed ? $self->_zoom_anchor_x() : undef;
    $self->_horizontal_zoom($step, $anchor_x);
}

# ============================================================================
# _horizontal_zoom: Zoom horizontal con anclaje (Req. 8.1, 8.2, 9.1-9.4)
# ============================================================================
sub _horizontal_zoom {
    my ($self, $delta, $anchor_x) = @_;

    my $total = $self->{market_data}->size();
    return unless $total && $total > 0;
    my $old_offset = $self->{offset};
    my $use_cursor_anchor = defined $anchor_x;

    # 1. Punto de anclaje (índice GLOBAL + X de pantalla) ANTES del zoom
    my ($anchor_index, $anchor_screen_x) = $use_cursor_anchor 
        ? $self->_anchor_index_and_x($anchor_x) 
        : $self->_anchor_index_and_x(undef);

    # 2. Nuevo número de velas visibles, acotado
    my $new_visible = $self->{visible_bars} + $delta;
    my $max_visible = $total < MAX_VISIBLE_BARS ? $total : MAX_VISIBLE_BARS;
    $new_visible = MIN_VISIBLE_BARS if $new_visible < MIN_VISIBLE_BARS;
    $new_visible = $max_visible     if $new_visible > $max_visible;

    # 3. Aplicar el nuevo zoom
    $self->{visible_bars} = $new_visible;

    # Si no usamos anclaje de cursor y ya estábamos pegados a la derecha, solo mantener offset
    if (!$use_cursor_anchor) {
        if ($old_offset <= 0) {
            $self->{offset} = $self->_clamp_offset($old_offset);
            $self->request_render();
            return;
        }
    }

    # 4. Nueva escala con el nuevo número de barras
    my $scale = Market::Panels::Scales->new(
        bars         => $new_visible,
        right_margin => RIGHT_MARGIN,
    );
    $scale->{width} = $self->_canvas_width($self->{price_canvas});

    # 5. Calcular nuevo offset para que el ancla quede en su X anterior
    #    Fórmula: local = X/bar_w - 0.5 (porque index_to_center_x = (local + 0.5) * bar_w)
    my $local_target = $scale->x_to_index_float($anchor_screen_x) - 0.5;
    my $end_idx      = $anchor_index + ($new_visible - 1 - $local_target);
    my $offset       = ($total - 1) - $end_idx;

    # 6. Acotar offset y renderizar
    $offset = $self->round($offset);
    $self->{offset} = $self->_clamp_offset($offset);
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
    
    # También aplicar arrastre vertical si corresponde (pan Y en modo manual)
    $self->_apply_vertical_drag_from_start($current_y);
    
    $self->request_render();   # Reprogramar render
}

# ============================================================================
# _on_time_axis_motion: Maneja movimiento del ratón sobre el eje temporal
# ============================================================================
sub _on_time_axis_motion {
    my ($self, $widget, $x, $y) = @_;

    return unless defined $x;
    $self->{last_mouse_x} = $self->round($x);
    $self->{last_mouse_y} = undef;   # Sin información Y en el eje temporal
    $self->{active_canvas} = $widget if defined $widget;
    $self->_draw_crosshair_all();
}

# ============================================================================
# _start_time_axis_drag: Inicia arrastre en el eje temporal (zoom horizontal)
# ============================================================================
sub _start_time_axis_drag {
    my ($self, $widget, $x, $y) = @_;

    my $root_x = eval { $widget->pointerx() };
    $self->{time_axis_drag_start_x} = defined $root_x ? $root_x : $x;
    $self->{time_axis_drag_visible} = $self->{visible_bars};
}

# ============================================================================
# _on_time_axis_drag: Maneja arrastre en el eje temporal (cambia visible_bars)
# ============================================================================
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
    return if $new_visible == $self->{visible_bars};   # Sin cambio, no hacer nada

    $self->_horizontal_zoom($new_visible - $self->{visible_bars}, undef);
}

# ============================================================================
# _end_time_axis_drag: Limpia estado del arrastre en el eje temporal
# ============================================================================
sub _end_time_axis_drag {
    my ($self) = @_;
    $self->{time_axis_drag_start_x} = undef;
    $self->{time_axis_drag_visible} = undef;
}

# ============================================================================
# _apply_vertical_drag_from_start: Aplica arrastre vertical (pan Y) durante un drag
# ============================================================================
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

# ============================================================================
# _start_price_axis_drag: Inicia arrastre en el eje lateral de precios (zoom Y)
# ============================================================================
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

# ============================================================================
# _on_price_axis_drag: Maneja arrastre en el eje lateral (zoom Y exponencial)
# ============================================================================
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

    # Factor exponencial: dy positivo (abajo) → factor > 1 → zoom out (aumenta half)
    my $factor = exp($dy / 220);
    $factor = 0.000001 if $factor < 0.000001;   # Evitar valores absurdos
    $half *= $factor;

    $self->{manual_min_y} = $center - $half;
    $self->{manual_max_y} = $center + $half;
    $self->{is_auto_scale} = 0;
    $self->request_render();
}

# ============================================================================
# _end_price_axis_drag: Limpia estado del arrastre en el eje lateral
# ============================================================================
sub _end_price_axis_drag {
    my ($self) = @_;
    $self->{axis_drag_start_y} = undef;
    $self->{axis_drag_min_y} = undef;
    $self->{axis_drag_max_y} = undef;
}

# ============================================================================
# set_scale_mode: Cambia entre escala automática y manual
# ============================================================================
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

# ============================================================================
# _on_resize: Maneja redimensionamiento de la ventana
# ============================================================================
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

# ============================================================================
# _end_drag: Limpia el estado después de un arrastre
# ============================================================================
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

# ============================================================================
# _vertical_drag: Desplazamiento vertical (pan Y) con teclas Up/Down
# ============================================================================
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

# ============================================================================
# _vertical_zoom: Zoom Y con teclas '+' y '-'
# ============================================================================
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

# ============================================================================
# _on_mouse_move: Maneja movimiento del ratón sobre cualquier canvas
# ============================================================================
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

# ============================================================================
# _crosshair_time_label: Genera etiqueta de tiempo para el crosshair (HH:MM o fecha completa)
# ⭐ MODIFICADO: Ahora muestra fecha completa "lun 29 Sep '26 20:36"
# ============================================================================
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

    # Detectar si es un cambio de día (medianoche)
    my $is_day_change = 0;
    my $anchors = $self->{market_data}->compute_time_anchors();
    for my $a (@$anchors) {
        if ($a->{is_date} && $a->{index} == $global) {
            $is_day_change = 1;
            last;
        }
    }

    # Devolver formato completo (fecha + hora) o solo fecha si es cambio de día
    return $self->_format_full_datetime($tm, $is_day_change);
}

# ============================================================================
# _format_full_datetime: Formatea fecha completa para el crosshair
# ⭐ NUEVA FUNCIÓN: Ejemplo "lun 29 Sep '26 20:36" o "lun 29 Sep '26"
# ============================================================================
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

    # Si es cambio de día, devolver solo la fecha
    return $date_part if $is_day_change;

    # Si no, agregar la hora: "lun 29 Sep '26 20:36"
    my $hour   = sprintf("%02d", $tm->hour);
    my $minute = sprintf("%02d", $tm->minute);
    return "$date_part $hour:$minute";
}

# ============================================================================
# _draw_crosshair_all: Dibuja el crosshair en todos los paneles y ejes
# ============================================================================
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

# ============================================================================
# set_timeframe: Cambia la temporalidad (1m, 5m, 15m)
# ============================================================================
sub set_timeframe {
    my ($self, $tf) = @_;

    if ($tf ne '1m' && $tf ne '5m' && $tf ne '15m') {
        warn "Temporalidad '$tf' no soportada por el sistema.";
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

# ============================================================================
# reset_view: Restablece la vista a los valores por defecto
# ============================================================================
sub reset_view {
    my ($self) = @_;

    $self->{visible_bars} = 60;   # Zoom por defecto
    $self->{offset} = 0;          # Scroll a la derecha (velas más recientes)
    $self->{is_auto_scale} = 1;   # Escala automática
    $self->{manual_min_y} = undef;
    $self->{manual_max_y} = undef;
    $self->request_render();
}

# ============================================================================
# compute_intraday_labels: Genera etiquetas del eje temporal inferior
# ============================================================================
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

# ============================================================================
# _time_label_for_index: Formatea un Time::Moment como 'HH:MM' o 'DD Mon'
# ============================================================================
sub _time_label_for_index {
    my ($self, $tm, $is_date) = @_;

    return undef unless defined $tm && ref($tm) eq 'Time::Moment';

    if ($is_date) {
        # ⭐ MEJORADO: Ahora muestra "lun 29 Sep" en lugar de "29 Sep"
        my @days = qw(dom lun mar mié jue vie sáb);
        my @months = qw(ene feb mar abr may jun jul ago sep oct nov dic);
        my $day_name = $days[$tm->day_of_week];
        my $day_num  = $tm->day_of_month;
        my $month    = $months[$tm->month - 1];
        return sprintf("%s %d %s", $day_name, $day_num, $month);
    }

    return sprintf("%02d:%02d", $tm->hour, $tm->minute);
}

# ============================================================================
# get_all_timestamps: Obtiene timestamps de todas las velas visibles (con extrapolación)
# ============================================================================
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
# _timeframe_minutes: Devuelve la duración en minutos del timeframe actual
# ============================================================================
sub _timeframe_minutes {
    my ($self) = @_;

    my $tf = eval { $self->{market_data}->{active_tf} } || '1m';
    return 5  if $tf eq '5m';
    return 15 if $tf eq '15m';
    return 1;   # '1m' o cualquier otro valor por defecto
}

1;