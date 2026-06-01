package Market::Panels::ATRPanel;
use strict;
use warnings;

# new(): Constructor del panel ATR. Recibe argumentos named (hash).
sub new {
    my ($class, %args) = @_;

    # Creamos el objeto con todos los argumentos recibidos.
    my $self = {
        %args,
        crosshair_objects => []   # Lista para guardar IDs de objetos del crosshair (aunque en este panel no se usa mucho)
    };
    # El tema (paleta clara) se inyecta vía `theme => \%theme` desde ChartEngine.
    # Garantizar robustez: si no llega, dejar un hashref vacío para que las lecturas
    # posteriores (con defaults //) sean seguras.
    $self->{theme} = {} unless defined $self->{theme};
    bless $self, $class;
    return $self;
}

# _init_crosshair(): Inicializa la lista de objetos del crosshair (no se usa mucho en este panel).
sub _init_crosshair {
    my ($self) = @_;
    $self->{crosshair_objects} = [];
}

# _canvas_size(): Obtiene el ancho y alto reales del canvas Tk.
# Maneja diferentes formas de obtener la geometría.
sub _canvas_size {
    my ($self, $canvas) = @_;
    my ($w, $h) = (0, 0);
    # Intentar obtener geometría con 'geometry()' (formato "ancho x alto")
    my $geom = eval { $canvas->geometry() };
    if (defined $geom && $geom =~ /^(\d+)x(\d+)/) {
        ($w, $h) = ($1, $2);
    }
    # Fallbacks: usar métodos Width/Height, width/height, o 1 por defecto.
    $w ||= eval { $canvas->Width() }  || eval { $canvas->width() }  || 1;
    $h ||= eval { $canvas->Height() } || eval { $canvas->height() } || 1;
    $w = 1 if $w < 1;
    $h = 1 if $h < 1;
    return ($w, $h);
}

# get_y_range(): Calcula el rango de valores visibles del ATR para escalar el eje Y.
# Recibe una lista de valores (algunos pueden ser undef durante warm-up).
# Devuelve (min, max) con un padding del 5%.
sub get_y_range {
    my ($self, $visible_values) = @_;

    # Si no hay valores definidos, devolver un rango por defecto (0,100).
    return (0, 100) if !@$visible_values;

    # Filtrar los valores definidos (ignorar undef del warm-up).
    my @defined = grep { defined $_ } @$visible_values;
    return (0, 100) unless @defined;

    # Encontrar mínimo y máximo.
    my $min = $defined[0];
    my $max = $defined[0];

    foreach my $val (@defined) {
        $min = $val if $val < $min;
        $max = $val if $val > $max;
    }

    # Agregar padding del 5% para que la línea no toque los bordes.
    my $padding = ($max - $min) * 0.05 || 1;
    return ($min - $padding, $max + $padding);
}

# set_scale(): Asigna el objeto Scales a este panel.
# Scales se encarga de convertir datos (índices, valores) a coordenadas de píxel.
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# render(): Dibuja la línea del ATR como polilínea sobre el canvas Tk.
sub render {
    my ($self, $canvas, $visible_values, $scale) = @_;

    $canvas->delete('all');   # Limpiar todo el canvas antes de dibujar

    return if !@$visible_values;  # No hay datos, salir

    # Inyectar dimensiones del canvas en el objeto scale
    my ($canvas_w, $canvas_h) = $self->_canvas_size($canvas);
    # ChartEngine puede inyectar un ancho compartido para sincronizar X con precio.
    $scale->{width}  ||= $canvas_w;
    $scale->{height} = $canvas_h;

    # Inyectar colores de eje del tema en la escala antes de dibujar el eje Y.
    # La conversión datos↔píxeles sigue viviendo en Scales; aquí solo se le pasan
    # los colores claros (con defaults seguros si el tema no está disponible).
    $scale->{grid_color}      = $self->{theme}{grid}      // '#e6e6e6';
    $scale->{axis_text_color} = $self->{theme}{axis_text} // '#363a45';

    # Dibujar el eje Y (con grid y números) usando el objeto scale.
    $scale->_draw_y_scale($canvas);
    $canvas->lower('y_grid');   # Enviar la grid al fondo para que no tape la línea

    # Construir la polilínea: pares (x, y) para cada valor definido.
    my @points;
    $self->{_last_value} = undef;   # Para la etiqueta del último valor

    for (my $i = 0; $i < @$visible_values; $i++) {
        my $val = $visible_values->[$i];
        next if !defined $val;      # Saltar valores undef (warm-up)

        # Convertir índice a coordenada X (centro de la barra)
        my $x = $scale->index_to_center_x($i);
        # Convertir valor ATR a coordenada Y (píxel)
        my $y = $scale->value_to_y($val);

        push @points, ($x, $y);
        $self->{_last_value} = $val;   # Actualizar el último valor definido
    }

    # Dibujar la línea si tenemos al menos 2 puntos (4 números en @points).
    if (@points >= 4) {
        my $atr_color = $self->{theme}{atr_line} // '#2962ff';  # Azul por defecto
        $canvas->createLine(@points, -fill => $atr_color, -width => 1.5, -tags => 'atr_line');
        $canvas->raise('atr_line');  # Traer la línea al frente
    }

    # Dibujar la etiqueta del último valor visible en el margen derecho.
    $self->render_last_visible_value($canvas);
}

# render_last_visible_value(): Muestra la etiqueta del último valor del ATR en el margen derecho.
sub render_last_visible_value {
    my ($self, $canvas) = @_;

    $canvas->delete('atr_last_label');   # Borrar etiqueta anterior si existe

    my $scale = $self->{scale};
    return unless defined $scale;
    # Si la escala tiene la bandera draw_last_label en false, no dibujar.
    return if exists $scale->{draw_last_label} && !$scale->{draw_last_label};
    return unless defined $self->{_last_value};   # No hay último valor, salir

    my $val   = $self->{_last_value};
    my $y     = $scale->value_to_y($val);         # Posición Y en píxeles
    my $w     = $scale->{width};                  # Ancho del canvas
    my $label = sprintf("%.4f", $val);            # Formatear con 4 decimales
    my $label_bg = $self->{theme}{last_price_bg} // '#363a45';
    my $label_fg = $self->{theme}{last_price_fg} // '#ffffff';
    my $line     = $self->{theme}{atr_line}      // '#2962ff';

    # Dibujar rectángulo de fondo de la etiqueta
    $canvas->createRectangle(
        $w - 68, $y - 7, $w, $y + 7,
        -fill    => $label_bg,
        -outline => $line,
        -tags    => 'atr_last_label',
    );
    # Dibujar texto de la etiqueta
    $canvas->createText(
        $w - 66, $y,
        -text   => $label,
        -anchor => 'w',   # Oeste (izquierda del texto)
        -font   => 'Helvetica 9 bold',
        -fill   => $label_fg,
        -tags   => 'atr_last_label',
    );
}

# draw_crosshair(): Dibuja el crosshair sincronizado en el sub-panel del ATR.
sub draw_crosshair {
    my ($self, $x, $y) = @_;

    my $canvas = $self->{canvas};
    return unless defined $canvas;

    $canvas->delete('atr_crosshair');   # Borrar crosshair anterior

    my ($width, $height) = $self->_canvas_size($canvas);

    # Color del crosshair tomado del tema (con default seguro para tema claro).
    my $crosshair_color = $self->{theme}{crosshair_line} // '#9598a1';

    # Línea vertical (si tenemos X)
    $canvas->createLine(
        $x, 0, $x, $height,
        -fill => $crosshair_color,
        -dash => '.',      # Línea punteada
        -tags => 'atr_crosshair',
    ) if defined $x;

    # Línea horizontal (si tenemos Y)
    $canvas->createLine(
        0, $y, $width, $y,
        -fill => $crosshair_color,
        -dash => '.',
        -tags => 'atr_crosshair',
    ) if defined $y;
}

1;