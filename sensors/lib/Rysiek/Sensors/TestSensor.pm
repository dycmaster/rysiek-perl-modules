package Rysiek::Sensors::TestSensor v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Sensors::AbstractSensor );
  use Dancer ':syntax';



#needed! contains whole logic of constant measuring and
#updating registered masters
  sub constantMeasurements{
    my $self = shift;
    sleep(2);

    while(1){
      my @res = $self->measureOnce();
      $self->updateMastersWithValue(\@res);
      sleep $self->sensorConfig()->[0]->{"constantMeasureFrequency"};
    }
  }

#needed for a single-shot measurement
  sub measureOnce{
    my @res = ("testValue", "true");
    return @res;
  }

  1;
}
