package Rysiek::Actions::SwitchAmpOn v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Actions::AbstractAction );
  use Dancer ':syntax';
  use WebService::Belkin::WeMo::Device;

  sub doAction{
    my $wemo = WebService::Belkin::WeMo::Device->new(name => config->{wemoAmpName}, db => config->{wemoDb});
    $wemo->on() unless $wemo->isSwitchOn();
    return "ok";
  }

  1;
}
