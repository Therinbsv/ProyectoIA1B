package Market::Panels::Scales;
# Gestiona la transformacion entre indices de datos y coordenadas en pantalla.
# Cada panel tiene su propio eje vertical Y independiente.
# El eje horizontal X es compartido entre todos los paneles.
# NUNCA mezclar coordenadas de datos con coordenadas de pantalla.
use strict;
use warnings;

# new: Inicializa sistema de escalas.
# Args obligatorios: min_val, max_val, width, height, visible_bars, offset
# Args opcionales:  padding (default 10)
sub new {
    my ($class, %args) = @_;
    my $self = { %args };
    $self->{padding} //= 10;

    # Evitar rango cero
    if ($self->{max_val} == $self->{min_val}) {
        $self->{max_val} += 1;
        $self->{min_val} -= 1;
    }
    bless $self, $class;
    return $self;
}

# Convierte indice de vela → coordenada X (borde izquierdo de la vela).
# Input: $index (entero, indice absoluto en el array)
# Output: coordenada X en pixeles
sub index_to_x {
    my ($self, $index) = @_;
    my $bar_w = $self->{width} / $self->{visible_bars};
    return ($index - $self->{offset}) * $bar_w;
}

# Convierte coordenada X → indice entero de vela.
# Input: $x (pixeles)
# Output: indice entero
sub x_to_index {
    my ($self, $x) = @_;
    my $bar_w = $self->{width} / $self->{visible_bars};
    return int($x / $bar_w) + $self->{offset};
}

# Convierte coordenada X → indice continuo (flotante) para mayor precision.
# Util para interaccion del mouse.
sub x_to_index_float {
    my ($self, $x) = @_;
    my $bar_w = $self->{width} / $self->{visible_bars};
    return $x / $bar_w + $self->{offset};
}

# Devuelve la coordenada X del centro de una vela.
# Input: $index (indice absoluto)
sub index_to_center_x {
    my ($self, $index) = @_;
    my $bar_w = $self->{width} / $self->{visible_bars};
    return ($index - $self->{offset} + 0.5) * $bar_w;
}

# Convierte valor (precio o indicador) → coordenada Y en pixeles.
# Los valores maximos van arriba (Y pequeño), minimos abajo (Y grande).
# Input: $value (numero)
# Output: coordenada Y en pixeles
sub value_to_y {
    my ($self, $value) = @_;
    my $min    = $self->{min_val};
    my $max    = $self->{max_val};
    my $range  = $max - $min;
    my $pad    = $self->{padding};
    my $h      = $self->{height};
    my $draw_h = $h - 2 * $pad;
    my $frac   = ($max - $value) / $range;
    return $pad + $frac * $draw_h;
}

# Convierte coordenada Y en pixeles → valor (precio o indicador).
# Input: $y (pixeles)
# Output: valor numerico
sub y_to_value {
    my ($self, $y) = @_;
    my $min    = $self->{min_val};
    my $max    = $self->{max_val};
    my $range  = $max - $min;
    my $pad    = $self->{padding};
    my $h      = $self->{height};
    my $draw_h = $h - 2 * $pad;
    my $frac   = ($y - $pad) / $draw_h;
    return $max - $frac * $range;
}

# Dibuja la escala vertical (eje Y) con lineas de grilla y etiquetas de precio.
# Input: $canvas (objeto Tk::Canvas)
sub _draw_y_scale {
    my ($self, $canvas) = @_;
    $canvas->delete('y_scale');

    my $min   = $self->{min_val};
    my $max   = $self->{max_val};
    my $range = $max - $min;
    return if $range <= 0;

    # Calcular paso "limpio" para etiquetas
    my $target_steps = 6;
    my $step = $range / $target_steps;
    my $exp  = int(log($step) / log(10));
    my $mant = $step / (10**$exp);
    if    ($mant <= 1.5) { $mant = 1; }
    elsif ($mant <= 3.5) { $mant = 2; }
    elsif ($mant <= 7.5) { $mant = 5; }
    else                 { $mant = 10; }
    $step = $mant * (10**$exp);

    my $first = int($min / $step) * $step;
    $first += $step if $first < $min;

    my $w   = $self->{width};
    my $pad = $self->{padding};

    for (my $val = $first; $val <= $max + $step / 2; $val += $step) {
        my $y = $self->value_to_y($val);
        next if $y < $pad || $y > $self->{height} - $pad;

        # Linea de grilla horizontal punteada
        $canvas->createLine(0, $y, $w - 65, $y,
            -fill => '#e0e0e0', -tags => 'y_scale', -dash => [4, 4]);

        # Etiqueta de precio sobre fondo blanco
        my $label = sprintf("%.2f", $val);
        $canvas->createText($w - 5, $y,
            -text   => $label,
            -anchor => 'e',
            -fill   => '#555555',
            -font   => ['Helvetica', 9],
            -tags   => 'y_scale');
    }
}

1;