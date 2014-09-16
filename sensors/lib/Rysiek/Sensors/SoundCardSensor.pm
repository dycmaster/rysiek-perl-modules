package Rysiek::Sensors::SoundCardSensor v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Sensors::AbstractSensor );
  use Dancer ':syntax';
  use Data::Dumper;
  use Net::OpenSSH;

#needed! contains whole logic of constant measuring and
#updating registered masters
  sub constantMeasurements{
    my $self = shift;
    sleep(2);

    my $last_state = "busy";

    while(1){

      my @res = $self->measureOnce();
      my $currState = $res[0];
      if($last_state ne $currState){
        debug("sound card status is now: @res");
        $self->updateMastersWithValue(\@res);
      }
      $last_state = $currState;

      sleep $self->sensorConfig()->[0]->{"constantMeasureFrequency"};
    }
  }

#needed for a single-shot measurement
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
