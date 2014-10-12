package Rysiek::Sensors::UserHomeWifi v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Sensors::AbstractSensor );
  use Dancer ':syntax';
  use Data::Dumper;
  use Net::OpenSSH;

  sub hasChanged{
    return 1;
  }

  sub measureOnce{
    my $self = shift;
    my $cfg  = $self->sensorConfig();
    my $cmd = "iw dev wlan0  station dump";

    if(! defined $self->{'ssh2'}){
      my $host =  $cfg->[0]->{"router-hostname"};
      my $user = $cfg->[0]->{"router-login"};
      my $pass = $cfg->[0]->{"router-password"};
      $self->{'ssh2'} = Net::OpenSSH->new("$user:$pass"."@".$host);
      $self->{'ssh2'}->error and debug("Can't ssh to $host: " . $self->{'ssh2'}->error);
      debug("SSH master client created");
    }

    my $stdout = $self->{'ssh2'}->capture($cmd);
    my @m = ( $stdout =~ /((?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2})/ig );
    my $trackedMac = $cfg->[0]->{trackedMac};

    if ( $trackedMac ~~ @m) {
      return "1";
    }else{
      return "0";
    }   

  }

  true;
}
