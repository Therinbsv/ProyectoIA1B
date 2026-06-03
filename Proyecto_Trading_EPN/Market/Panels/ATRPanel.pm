package Market::Panels::ATRPanel;
use strict;
use warnings;

# CONSTRUCTOR
sub new {
    my ($class, %args) = @_;

    my $self = {
        %args,
        crosshair_objects => [],   # Almacena IDs de objetos crosshair
    };
    
    # Asegurar que theme exista (con fallback seguro)
    $self->{theme} = {} unless defined $self->{theme};
    
    bless $self, $class;
    return $self;
}

# Inicializa el crosshair (limpia objetos antiguos)
sub _init_crosshair {
    my ($self) = @_;
    $self->{crosshair_objects} = [];
}

# Obtiene dimensiones reales del canvas Tk
sub _canvas_size {
    my ($self, $canvas) = @_;
    return (1, 1) unless $canvas;
    
    my ($w, $h) = (0, 0);
    my $geom = eval { $canvas->geometry() };
    
    if (defined $geom && $geom =~ /^(\d+)x(\d+)/) {
        ($w, $h) = ($1, $2);
    }
    
    # Fallbacks si geometry() falla
    $w ||= eval { $canvas->Width() }  || eval { $canvas->width() }  || 1;
    $h ||= eval { $canvas->Height() } || eval { $canvas->height() } || 1;
    
    # Asegurar valores positivos
    $w = 1 if $w < 1;
    $h = 1 if $h < 1;
    
    return ($w, $h);
}

# Calcula rango Y con padding del 5% para la línea ATR
sub get_y_range {
    my ($self, $visible_values) = @_;

    # Si no hay datos, devolver rango por defecto
    return (0, 100) if !@$visible_values;

    # Filtrar valores definidos (ignorar undef del warm-up)
    my @defined = grep { defined $_ } @$visible_values;
    return (0, 100) unless @defined;

    # Encontrar mínimo y máximo
    my $min = $defined[0];
    my $max = $defined[0];

    foreach my $val (@defined) {
        $min = $val if $val < $min;
        $max = $val if $val > $max;
    }

    # Agregar padding del 5% (mínimo 1 si el rango es 0)
    my $padding = ($max - $min) * 0.05;
    $padding = 1 if $padding <= 0;
    
    return ($min - $padding, $max + $padding);
}

# Asigna el objeto Scales a este panel
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# Renderiza la línea ATR en el canvas
sub render {
    my ($self, $canvas, $visible_values, $scale) = @_;

    # Limpiar canvas
    $canvas->delete('all');
    return if !@$visible_values;

    # Obtener dimensiones del canvas
    my ($canvas_w, $canvas_h) = $self->_canvas_size($canvas);
    $scale->{width}  ||= $canvas_w;
    $scale->{height} = $canvas_h;

    # Configurar colores de la escala desde el tema
    $scale->{grid_color}      = $self->{theme}{grid}      // '#2a2e39';
    $scale->{axis_text_color} = $self->{theme}{axis_text} // '#787b86';

    # Dibujar grid y eje Y
    $scale->_draw_y_scale($canvas);
    $canvas->lower('y_grid');

    # Construir puntos de la línea
    my @points;
    $self->{_last_value} = undef;

    for (my $i = 0; $i < @$visible_values; $i++) {
        my $val = $visible_values->[$i];
        next if !defined $val;

        my $x = $scale->index_to_center_x($i);
        my $y = $scale->value_to_y($val);

        push @points, ($x, $y);
        $self->{_last_value} = $val;
    }

    # Dibujar la línea ATR
    if (@points >= 4) {
        my $atr_color = $self->{theme}{atr_line} // '#386cfb';
        $canvas->createLine(@points, 
            -fill  => $atr_color, 
            -width => 1.5, 
            -tags  => 'atr_line'
        );
        $canvas->raise('atr_line');
    }

    # Mostrar etiqueta del último valor
    $self->_render_last_value_label($canvas);
}

# Renderiza la etiqueta del último valor ATR en el margen derecho
sub _render_last_value_label {
    my ($self, $canvas) = @_;

    $canvas->delete('atr_last_label');

    my $scale = $self->{scale};
    return unless defined $scale;
    
    # Verificar si debemos dibujar la etiqueta
    return if exists $scale->{draw_last_label} && !$scale->{draw_last_label};
    return unless defined $self->{_last_value};

    my $val   = $self->{_last_value};
    my $y     = $scale->value_to_y($val);
    my $w     = $scale->{width} || 500;
    my $label = sprintf("%.4f", $val);
    
    # Colores desde el tema
    my $label_bg = $self->{theme}{last_price_bg} // '#2a2e39';
    my $label_fg = $self->{theme}{last_price_fg} // '#d1d4dc';
    my $line     = $self->{theme}{atr_line}      // '#386cfb';

    # Fondo de la etiqueta
    $canvas->createRectangle(
        $w - 68, $y - 7, $w, $y + 7,
        -fill    => $label_bg,
        -outline => $line,
        -tags    => 'atr_last_label',
    );
    
    # Texto de la etiqueta
    $canvas->createText(
        $w - 66, $y,
        -text   => $label,
        -anchor => 'w',
        -font   => 'Helvetica 9 bold',
        -fill   => $label_fg,
        -tags   => 'atr_last_label',
    );
}

# Dibuja el crosshair (líneas vertical/horizontal) CON SOPORTE PARA ETIQUETA DE TIEMPO
sub draw_crosshair {
    my ($self, $x, $y, $time_text) = @_;

    my $canvas = $self->{canvas};
    return unless defined $canvas;

    # Limpiar crosshair anterior
    $canvas->delete('atr_crosshair');

    my ($width, $height) = $self->_canvas_size($canvas);
    
    # Color del crosshair (con fallback para compatibilidad)
    my $crosshair_color = $self->{theme}{crosshair_line} // '#b2b5be';
    my $label_bg = $self->{theme}{label_bg} // '#2a2e39';
    my $label_fg = $self->{theme}{label_fg} // '#d1d4dc';

    # Línea vertical
    if (defined $x) {
        $canvas->createLine(
            $x, 0, $x, $height,
            -fill => $crosshair_color,
            -dash => '.',
            -tags => 'atr_crosshair',
        );
    }
    
    # Línea horizontal
    if (defined $y) {
        $canvas->createLine(
            0, $y, $width, $y,
            -fill => $crosshair_color,
            -dash => '.',
            -tags => 'atr_crosshair',
        );
    }
    
    # Etiqueta de tiempo en la banda inferior (igual que en PricePanel)
    if (defined $time_text && defined $x && length $time_text) {
        my $box_h     = 16;
        my $char_w    = 6;
        my $pad_x     = 6;
        my $half_w    = (length($time_text) * $char_w) / 2 + $pad_x;
        
        my $cx = $x;
        $cx = $half_w      if $cx - $half_w < 0;
        $cx = $width - $half_w if $cx + $half_w > $width;
        
        my $top    = $height - $box_h;
        my $bottom = $height;
        
        $canvas->createRectangle(
            $cx - $half_w, $top, $cx + $half_w, $bottom,
            -fill    => $label_bg,
            -outline => $crosshair_color,
            -tags    => 'atr_crosshair',
        );
        $canvas->createText(
            $cx, $top + $box_h / 2,
            -text   => $time_text,
            -anchor => 'center',
            -font   => 'Helvetica 9 bold',
            -fill   => $label_fg,
            -tags   => 'atr_crosshair',
        );
    }
}

1;