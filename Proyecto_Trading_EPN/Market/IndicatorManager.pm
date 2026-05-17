package Market::IndicatorManager;
# Gestiona multiples indicadores tecnicos de forma desacoplada.
# Permite registrar, actualizar y consultar indicadores
# sin acoplarlos al sistema de render.
use strict;
use warnings;

sub new {
    my ($class) = @_;
    my $self = {
        indicators => {},   # nombre => objeto indicador
    };
    bless $self, $class;
    return $self;
}

# Registra un indicador con un nombre clave.
# Input: $name (string), $indicator (objeto con update_last, get_values, reset)
sub register {
    my ($self, $name, $indicator) = @_;
    $self->{indicators}{$name} = $indicator;
}

# Actualiza todos los indicadores con la ultima vela (calculo incremental).
# Input: $market_data objeto Market::MarketData
sub update_last {
    my ($self, $market_data) = @_;
    for my $ind (values %{ $self->{indicators} }) {
        $ind->update_last($market_data) if $ind->can('update_last');
    }
}

# Obtiene el objeto indicador por nombre.
# Output: objeto indicador o undef
sub get {
    my ($self, $name) = @_;
    return $self->{indicators}{$name};
}

# Devuelve una porcion de valores del indicador para la ventana visible.
# Input: $name, $start (indice inicio), $end (indice fin)
# Output: arrayref de valores (puede contener undef)
sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $ind = $self->get($name);
    return [] unless $ind && $ind->can('get_values');
    my $all = $ind->get_values();
    return [] unless $all && @$all;
    $start = 0       if $start < 0;
    $end   = $#$all  if $end > $#$all;
    return []        if $start > $end;
    return [ @{$all}[$start .. $end] ];
}

# Reinicia todos los indicadores (util al cambiar timeframe).
sub reset_all {
    my ($self) = @_;
    for my $ind (values %{ $self->{indicators} }) {
        $ind->reset() if $ind->can('reset');
    }
}

1;