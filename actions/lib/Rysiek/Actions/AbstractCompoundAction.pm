package Rysiek::Actions::AbstractCompoundAction v0.0.1{
  use 5.014;
  use Moose;
  extends qw( Rysiek::Actions::AbstractAction );
  use Dancer ':syntax';

  sub doAction{
    return 1;
  }

  1;
}
