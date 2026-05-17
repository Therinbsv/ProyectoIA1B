package Market::Panels::ATRPanel;
# Renderiza el indicador ATR en un panel separado con su propia escala vertical.
# Responsabilidad unica: SOLO renderizado del ATR, SIN logica de calculo.
use strict;
use warnings;
use List::Util qw(min max);

sub new {
    my ($class, %args) = @_;
    my $self = {
        line_color  => $args{line_color}  // '#c0392b',   # rojo oscuro como TradingView
        line_width  => $args{line_width}  // 1,
        canvas      => undef,
        scale       => undef,
        values      => [],
        # IDs de items del crosshair
        _ch_v       => undef,
        _ch_h       => undef,
        _ch_val     => undef,
        _ch_box     => undef,
    };
    bless $self, $class;
    return $self;
}

# Crea los objetos graficos del crosshair en el panel ATR.
# Input: $canvas (Tk::Canvas)
sub _init_crosshair {
    my ($self, $canvas) = @_;
    $self->{canvas} = $canvas;
    $canvas->delete('crosshair');
    # Linea vertical
    $self->{_ch_v} = $canvas->createLine(0,0,0,0,
        -fill => '#999999', -dash => [3,3], -tags => 'crosshair', -state => 'hidden');
    # Linea horizontal
    $self->{_ch_h} = $canvas->createLine(0,0,0,0,
        -fill => '#999999', -dash => [3,3], -tags => 'crosshair', -state => 'hidden');
    # Caja del valor en eje Y
    $self->{_ch_box} = $canvas->createRectangle(0,0,0,0,
        -fill => '#131722', -outline => '#131722', -tags => 'crosshair', -state => 'hidden');
    # Texto del valor en eje Y
    $self->{_ch_val} = $canvas->createText(0,0,
        -text => '', -fill => '#ffffff', -font => ['Helvetica', 9],
        -anchor => 'e', -tags => 'crosshair', -state => 'hidden');
}

# Calcula el rango min/max de los valores ATR visibles con padding del 5%.
# Input: $values (arrayref, puede contener undef)
# Output: ($min_val, $max_val)
sub get_y_range {
    my ($self, $values) = @_;
    return (0, 1) unless $values && @$values;
    my @valid = grep { defined $_ } @$values;
    return (0, 1) unless @valid;
    my $mn  = min(@valid);
    my $mx  = max(@valid);
    my $pad = ($mx - $mn) * 0.1;
    $pad = 0.01 if $pad < 0.01;
    return ($mn - $pad, $mx + $pad);
}

# Asigna la escala vertical al panel.
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# Renderiza la linea del ATR en el canvas.
# Input: $canvas (Tk::Canvas), $values (arrayref), $scale (Scales)
sub render {
    my ($self, $canvas, $values, $scale) = @_;
    $canvas->delete('atr_line');
    return unless $values && @$values;

    $self->{scale}  = $scale;
    $self->{values} = $values;
    $self->{canvas} = $canvas;

    my ($prev_x, $prev_y);
    for my $i (0 .. $#$values) {
        my $val = $values->[$i];
        next unless defined $val;

        my $idx = $scale->{offset} + $i;
        my $x   = $scale->index_to_center_x($idx);
        my $y   = $scale->value_to_y($val);

        if (defined $prev_x) {
            $canvas->createLine($prev_x, $prev_y, $x, $y,
                -fill  => $self->{line_color},
                -width => $self->{line_width},
                -tags  => 'atr_line');
        }
        $prev_x = $x;
        $prev_y = $y;
    }
}

# Muestra el ultimo valor ATR visible con caja en el eje Y.
# Input: $canvas (Tk::Canvas)
sub render_last_visible_value {
    my ($self, $canvas) = @_;
    $canvas->delete('last_atr');
    return unless $self->{scale} && $self->{values} && @{ $self->{values} };

    my $last_val;
    for my $v (reverse @{ $self->{values} }) {
        if (defined $v) { $last_val = $v; last; }
    }
    return unless defined $last_val;

    my $y     = $self->{scale}->value_to_y($last_val);
    my $w     = $self->{scale}->{width};
    my $label = sprintf("%.2f", $last_val);

    $canvas->createRectangle($w - 63, $y - 8, $w, $y + 8,
        -fill => '#c0392b', -outline => '#c0392b', -tags => 'last_atr');
    $canvas->createText($w - 4, $y,
        -text => $label, -anchor => 'e',
        -fill => '#ffffff', -font => ['Helvetica', 9],
        -tags => 'last_atr');
}

# Dibuja el crosshair sincronizado en el panel ATR.
# Input: $x, $y (coordenadas del mouse en este panel)
sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas && defined $self->{_ch_v};

    my $scale = $self->{scale};
    return unless $scale;

    my $w = $scale->{width};
    my $h = $scale->{height};

    $canvas->coords($self->{_ch_v}, $x, 0, $x, $h);
    $canvas->itemconfigure($self->{_ch_v}, -state => 'normal');

    $canvas->coords($self->{_ch_h}, 0, $y, $w, $y);
    $canvas->itemconfigure($self->{_ch_h}, -state => 'normal');

    # Valor ATR en eje Y
    my $val     = $scale->y_to_value($y);
    my $val_lbl = sprintf("%.3f", $val);
    $canvas->coords($self->{_ch_box}, $w - 65, $y - 9, $w, $y + 9);
    $canvas->itemconfigure($self->{_ch_box}, -state => 'normal');
    $canvas->coords($self->{_ch_val}, $w - 4, $y);
    $canvas->itemconfigure($self->{_ch_val}, -state => 'normal', -text => $val_lbl);

    $canvas->raise('crosshair');
}

# Oculta el crosshair.
sub hide_crosshair {
    my ($self) = @_;
    my $canvas = $self->{canvas};
    return unless $canvas;
    $canvas->itemconfigure('crosshair', -state => 'hidden');
}

1;