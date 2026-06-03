package Market::Panels::Scales;
use strict;
use warnings;

# new(): Constructor. Recibe parámetros named (hash) con:
sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
    };
    # Margen derecho opcional. Solo afecta al eje X (ploteo horizontal).
    $self->{right_margin} = 0 unless defined $self->{right_margin};
    $self->{x_shift} = 0 unless defined $self->{x_shift};
    bless $self, $class;
    return $self;
}

# plot_width(): Ancho del área de ploteo (excluyendo margen derecho).
sub plot_width {
    my ($self) = @_;
    my $w = ($self->{width} // 0) - ($self->{right_margin} // 0);
    return $w > 1 ? $w : 1;
}

# index_to_x(): Convierte índice de barra (0-based) al borde IZQUIERDO en píxeles.
# Útil para dibujar rectángulos que empiezan en el borde de la barra.
sub index_to_x {
    my ($self, $index) = @_;
    my $bars  = $self->{bars} || 1;
    my $bar_w = $self->plot_width / $bars;
    my $x_shift = $self->{x_shift} || 0;
    return $index * $bar_w + $x_shift;
}

# x_to_index(): Convierte coordenada X (píxel) al índice de barra ENTERO.
sub x_to_index {
    my ($self, $x) = @_;
    my $bars  = $self->{bars} || 1;
    my $bar_w = $self->plot_width / $bars;
    return 0 if $bar_w <= 0;
    my $x_shift = $self->{x_shift} || 0;
    my $idx = int(($x - $x_shift) / $bar_w + 1e-9);  # floor con epsilon
    $idx = 0         if $idx < 0;
    $idx = $bars - 1 if $idx >= $bars;  # clamp al rango válido
    return $idx;
}

# x_to_index_float(): Versión en punto flotante para zoom con anclaje.
sub x_to_index_float {
    my ($self, $x) = @_;
    my $bars  = $self->{bars} || 1;
    my $bar_w = $self->plot_width / $bars;
    return 0 if $bar_w <= 0;
    my $x_shift = $self->{x_shift} || 0;
    return ($x - $x_shift) / $bar_w;
}

# index_to_center_x(): Centro de la barra (usado para velas y línea ATR).
# Fórmula: borde izquierdo + mitad del ancho.
sub index_to_center_x {
    my ($self, $index) = @_;
    my $bars  = $self->{bars} || 1;
    my $bar_w = $self->plot_width / $bars;
    my $x_shift = $self->{x_shift} || 0;
    return $index * $bar_w + $bar_w / 2 + $x_shift;
}

# value_to_y(): Valor financiero (precio, ATR) → coordenada Y (píxeles).
sub value_to_y {
    my ($self, $value) = @_;
    my $range = $self->{max_y} - $self->{min_y};
    return 0 if $range == 0;
    return (($self->{max_y} - $value) / $range) * $self->{height};
}

# y_to_value(): Operación inversa: Y píxel → valor financiero.
# Útil para el crosshair: cuando el mouse pasa por Y, convertimos a precio/ATR.
sub y_to_value {
    my ($self, $y) = @_;
    my $range = $self->{max_y} - $self->{min_y};
    return $self->{min_y} unless $self->{height};
    return $self->{max_y} - ($y / $self->{height}) * $range;
}

# _draw_y_scale(): Dibuja el eje Y (grid horizontal + etiquetas de valor).
sub _draw_y_scale {
    my ($self, $canvas) = @_;
    return unless defined $canvas;

    my $width  = $self->{width}  // 0;
    my $height = $self->{height} // 0;
    my $min    = $self->{min_y};
    my $max    = $self->{max_y};
    return unless defined $min && defined $max;

    my $range = $max - $min;
    return if $range == 0;

    # Borrar marcas anteriores del eje Y (pero NO el contenido principal).
    $canvas->delete('y_scale');

    # Colores del tema claro inyectados por el panel (con defaults seguros).
    my $grid_color = $self->{grid_color}      // '#e6e6e6';
    my $text_color = $self->{axis_text_color} // '#363a45';

    # Elegir paso "limpio" (función helper _clean_step).
    my $step = _clean_step($min, $max, $range, $height);
    return if !defined $step || $step <= 0;

    my $draw_grid   = exists $self->{draw_grid}   ? $self->{draw_grid}   : 1;
    my $draw_labels = exists $self->{draw_labels} ? $self->{draw_labels} : 1;

    # Primer múltiplo del paso que sea >= min_y
    my $first_k = _ceil_div($min, $step);
    for (my $k = $first_k; $k * $step <= $max + $step * 1e-9; $k++) {
        my $val = $k * $step;
        my $y   = $self->value_to_y($val);

        # Línea de grid horizontal (opcional, ancho completo)
        if ($draw_grid) {
            $canvas->createLine(
                0, $y, $width, $y,
                -fill => $grid_color,
                -tags => ['y_scale', 'y_grid'],
            );
        }

        next unless $draw_labels;

        # Etiqueta numérica: más decimales para valores pequeños, menos para grandes.
        my $label = (abs($val) >= 100) ? sprintf("%.2f", $val) : sprintf("%.4f", $val);
        my $label_x      = defined $self->{label_x}      ? $self->{label_x}      : $width - 2;
        my $label_anchor = defined $self->{label_anchor} ? $self->{label_anchor} : 'e';
        $canvas->createText(
            $label_x, $y,
            -text   => $label,
            -anchor => $label_anchor,
            -font   => 'Helvetica 8',
            -fill   => $text_color,
            -tags   => 'y_scale',
        );
    }
}

# _floor(): sin depender de POSIX (int() trunca hacia 0, no hacia -inf).
sub _floor {
    my ($x) = @_;
    my $i = int($x);
    return ($x < 0 && $x != $i) ? $i - 1 : $i;
}

# _ceil(): sin depender de POSIX.
sub _ceil {
    my ($x) = @_;
    my $i = int($x);
    return ($x > 0 && $x != $i) ? $i + 1 : $i;
    my $n = shift;
    return int($n) + 1 if $n > int($n);
    return int($n);
}

# _ceil_div(): Menor entero k tal que k*step >= value.
sub _ceil_div {
    my ($value, $step) = @_;
    return _ceil($value / $step - 1e-9);
}

# _label_count(): Cuántos múltiplos enteros de $step hay en [$min, $max].
sub _label_count {
    my ($min, $max, $step) = @_;
    return 0 if $step <= 0;
    my $first = _ceil($min / $step - 1e-9);
    my $last  = _floor($max / $step + 1e-9);
    my $n = $last - $first + 1;
    return $n < 0 ? 0 : $n;
}

# _clean_step(): Elige un paso "limpio" para el eje Y estilo TradingView.
sub _clean_step {
    my ($min, $max, $range, $height) = @_;
    my $abs_range = abs($range);
    return $range if $abs_range == 0;   # salvaguarda

    # Exponente base del rango para generar candidatos alrededor de range/5.
    my $exp = _floor(log($abs_range) / log(10));

    my @mult = (1, 2, 2.5, 5);
    my @cands;
    for my $e ($exp - 2 .. $exp + 1) {
        my $mag = 10 ** $e;
        push @cands, $_ * $mag for @mult;
    }
    @cands = sort { $a <=> $b } grep { $_ > 0 } @cands;

    # Candidatos que producen entre 6 y 12 etiquetas.
    my @valid;
    for my $s (@cands) {
        my $c = _label_count($min, $max, $s);
        next unless $c >= 6 && $c <= 12;
        my $sep = $height > 0 ? ($s / $abs_range) * $height : 0;
        push @valid, { step => $s, count => $c, sep => $sep };
    }

    if (@valid) {
        # Preferir separación vertical >= 20 px; si ninguno la cumple, usar todos.
        my @ok   = grep { $height <= 0 || $_->{sep} >= 20 } @valid;
        my @pool = @ok ? @ok : @valid;
        # Ordenar por cercanía a 9 etiquetas, luego por separación, luego por paso.
        @pool = sort {
            abs($a->{count} - 9) <=> abs($b->{count} - 9)
                || $b->{sep} <=> $a->{sep}
                || $a->{step} <=> $b->{step}
        } @pool;
        return $pool[0]{step};
    }

    # Fallback: el candidato cuya cantidad de etiquetas más se acerque a [6,12].
    my @scored = map {
        my $c    = _label_count($min, $max, $_);
        my $dist = $c < 6 ? (6 - $c) : ($c > 12 ? ($c - 12) : 0);
        { step => $_, dist => $dist, count => $c };
    } @cands;
    @scored = sort { $a->{dist} <=> $b->{dist} || $b->{count} <=> $a->{count} } @scored;
    return @scored ? $scored[0]{step} : ($abs_range / 5);
}

1;