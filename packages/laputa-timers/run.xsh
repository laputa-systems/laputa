#!/usr/bin/xsh
##! Entry point for the supervised timer scheduler.
##!
##! The entry script owns the termination hook: on TERM or INT the scope
##! cleanup cancels and reaps every job process group the scheduler owns.

type TimersModule = module {
  export proc timers_main(...argv: List[Str]) [fs, process, time, env, io, error] -> Result[Unit, Error]
}

on TERM [process] {
  exit 0
}

on INT [process] {
  exit 0
}

proc main(...argv: List[Str]) [fs, process, time, env, io, error] {
  let loaded = module.load(p"/usr/lib/laputa/timers.xsh")?
  let scheduler = loaded.require(TimersModule)?
  scheduler.timers_main(@argv)
}

main(@args)?
