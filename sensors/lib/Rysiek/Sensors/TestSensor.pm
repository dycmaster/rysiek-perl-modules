package Rysiek::Sensors::TestSensor v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Sensors::AbstractSensor );
  use Dancer ':syntax';

  sub measureOnce{
    my @res = ("testValue", "true");
    return @res;
  }

  1;
}
