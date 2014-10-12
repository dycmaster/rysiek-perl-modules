package Rysiek::Sensors::SoundCardSensor v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Sensors::AbstractSensor );
  use Dancer ':syntax';
  use Data::Dumper;
  use Net::OpenSSH;

  has "+lastValue" => (
    default => ()
  );

  sub hasChanged{
    my $self = shift;
    my $currVal = shift;
    return 0 if(($self->lastValue)[0] eq @$currVal[0]);
    return 1;
  }

  sub measureOnce{
    my $self = shift;
    my $pathToCheck = $self->sensorConfig()->[0]->{"pathToCheck"};

    my $cfg  = $self->sensorConfig();
    my $cmd = "cat ".$pathToCheck;
    my $firstLine;

    if( $cfg->[0]->{"local"} eq 1 ){
      open my $file, '<', $self->sensorConfig()->[0]->{"pathToCheck"} or die; 
      $firstLine = <$file>; 
      close $file;
    }else{
      my $host =  $cfg->[0]->{"host"};
      my $user = $cfg->[0]->{"user"};
      my $pass = $cfg->[0]->{"pass"};
      my $ssh2 = Net::OpenSSH->new("$user:$pass"."@".$host);
      $ssh2->error and debug("Can't ssh to $host: " . $ssh2->error);
      my @stdout = $ssh2->capture($cmd);
      $firstLine = $stdout[0];
    }

    my @res;
    if($firstLine=~/\s*closed\s*/i){
      @res =("0");
    }else{
      @res =("1");
    }
    return @res;
  }
  1;
}
