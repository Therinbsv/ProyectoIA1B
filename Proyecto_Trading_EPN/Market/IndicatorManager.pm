package Market::IndicatorManager;  # Declara el espacio de nombres del módulo
use strict;                        # Obliga a declarar variables con 'my'
use warnings;                      # Muestra advertencias para evitar errores comunes

# ============================================================================
# new(): Constructor del contenedor de indicadores
# ============================================================================
sub new {
    my ($class) = @_;                    # $class es 'Market::IndicatorManager'
    my $self = {
        indicators => {},                # Hash vacío para almacenar indicadores
    };
    bless $self, $class;                 # "Bendecir" el hashref como objeto
    return $self;                        # Devolver el objeto recién creado
}

# ============================================================================
# register(): Registra un indicador en el contenedor
# ============================================================================
sub register {
    my ($self, $name, $indicator) = @_;
    
    # Validación: el nombre no puede ser undef ni cadena vacía
    die "register: name is required"      unless defined $name && length $name;
    
    # Validación: el objeto indicador debe existir
    die "register: indicator is required" unless defined $indicator;
    
    # Validación: el indicador debe tener método update_last (usando 'can' de Perl)
    die "register: indicator '$name' does not implement update_last"
        unless $indicator->can('update_last');
    
    # Validación: el indicador debe tener método get_values
    die "register: indicator '$name' does not implement get_values"
        unless $indicator->can('get_values');

    # Guardar el indicador en el hash con su nombre como clave
    $self->{indicators}->{$name} = $indicator;
    
    return $self;    # Devolver $self para poder encadenar llamadas
}

# ============================================================================
# update_last(): Propaga UNA nueva vela a TODOS los indicadores registrados
# ============================================================================
sub update_last {
    my ($self, $market_data, $index) = @_;
    
    # Si no hay datos de mercado, salir sin hacer nada
    return unless defined $market_data;

    # Iterar sobre cada indicador registrado
    for my $name (keys %{ $self->{indicators} }) {
        # Llamar al método update_last del indicador con los mismos parámetros
        $self->{indicators}->{$name}->update_last($market_data, $index);
    }
    return;
}

# ============================================================================
# get(): Devuelve la serie completa de valores de un indicador por su nombre
# ============================================================================
sub get {
    my ($self, $name) = @_;
    
    # Buscar el indicador por su nombre
    my $indicator = $self->{indicators}->{$name};
    
    # Si no existe, devolver undef
    return undef unless $indicator;
    
    # Devolver la serie de valores llamando a get_values del indicador
    return $indicator->get_values();
}

# ============================================================================
# slice_array(): Devuelve una porción de valores (para la ventana visible)
# ============================================================================
sub slice_array {
    my ($self, $name, $start, $end) = @_;
    
    # Obtener la serie completa del indicador
    my $values = $self->get($name);
    
    # Si no hay valores o el array está vacío, devolver array vacío
    return [] unless $values && @$values;
    
    # Si los índices no están definidos o start > end, devolver array vacío
    return [] if !defined $start || !defined $end || $start > $end;

    # Construir el slice
    my @slice;
    for my $i ($start .. $end) {
        # Si el índice está dentro del rango del array, tomar el valor
        # Si no, poner undef (para mantener el tamaño correcto)
        push @slice, ($i >= 0 && $i <= $#$values) ? $values->[$i] : undef;
    }
    return \@slice;
}

# ============================================================================
# reset_all(): Reinicia TODOS los indicadores registrados
# ============================================================================
sub reset_all {
    my ($self) = @_;
    
    # Paso 1 del recálculo al cambiar timeframe (Req. 13.4): reinicia cada indicador
    # ChartEngine::set_timeframe llama a este método y luego recalcula
    # vela por vela con update_last (paso 2). Sin dependencias de render.
    for my $name (keys %{ $self->{indicators} }) {
        my $indicator = $self->{indicators}->{$name};
        # Llamar a reset solo si el indicador implementa ese método
        $indicator->reset() if $indicator->can('reset');
    }
    return;
}

1;