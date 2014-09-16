package Rysiek::Actions::TestAction v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Actions::AbstractAction );
  use Dancer ':syntax';

  sub doAction{
    return "cool :)";
  }

  1;
}
