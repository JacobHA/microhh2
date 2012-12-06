#include <cstdio>
#include "grid.h"
#include "fields.h"
#include "mpiinterface.h"
#include "boundary.h"
#include "advec.h"
#include "diff.h"
#include "force.h"
#include "buoyancy.h"
#include "pres.h"
#include "buffer.h"
#include "timeloop.h"
#include "stats.h"
#include "cross.h"

int main(int argc, char *argv[])
{
  // set the name of the simulation
  std::string simname("microhh");
  if(argc > 1)
    simname = argv[1];

  // start up the message passing interface
  cmpi mpi;
  mpi.startup();

  // create the instances of the objects
  cinput  input (&mpi);
  cgrid   grid  (&mpi);
  cfields fields(&grid, &mpi);

  // create the boundary conditions class
  cboundary boundary(&grid, &fields, &mpi);

  // create the instances of the model operations
  ctimeloop timeloop(&grid, &fields, &mpi);
  cadvec    advec   (&grid, &fields, &mpi);
  cdiff     diff    (&grid, &fields, &mpi);
  cpres     pres    (&grid, &fields, &mpi);
  cforce    force   (&grid, &fields, &mpi);
  cbuoyancy buoyancy(&grid, &fields, &mpi);
  cbuffer   buffer  (&grid, &fields, &mpi);

  // load the postprocessing modules
  cstats    stats   (&grid, &fields, &mpi);
  ccross    cross   (&grid, &fields, &mpi);

  // read the input data
  if(input.readinifile(simname))
    return 1;
  if(mpi.readinifile(&input))
    return 1;
  if(grid.readinifile(&input))
    return 1;
  if(fields.readinifile(&input))
    return 1;
  if(boundary.readinifile(&input))
    return 1;
  if(advec.readinifile(&input))
    return 1;
  if(diff.readinifile(&input))
    return 1;
  if(force.readinifile(&input))
    return 1;
  if(buoyancy.readinifile(&input))
    return 1;
  if(buffer.readinifile(&input))
    return 1;
  if(pres.readinifile(&input))
    return 1;
  if(timeloop.readinifile(&input))
    return 1;
  if(stats.readinifile(&input))
    return 1;
  if(cross.readinifile(&input))
    return 1;

  // init the mpi 
  if(mpi.init())
    return 1;
  if(grid.init())
    return 1;
  if(fields.init())
    return 1;
  if(buffer.init())
    return 1;
  if(pres.init())
    return 1;
  if(stats.init())
    return 1;

  // free the memory of the input
  input.clear();

  // fill the fields with data
  if(grid.load())
    return 1;
  if(timeloop.load(timeloop.iteration))
    return 1;
  if(fields.load(timeloop.iteration))
    return 1;
  if(buffer.load())
    return 1;
  if(stats.create(simname, timeloop.iteration))
    return 1;

  // initialize the diffusion to get the time step requirement
  if(boundary.setvalues())
    return 1;
  if(diff.setvalues())
    return 1;
  if(pres.setvalues())
    return 1;

  // initialize the check variables
  int    iter;
  double time, dt;
  double mom, tke, mass;
  double div;
  double cfl, dn;
  double cputime, start, end;

  // write output file header to the main processor and set the time
  FILE *dnsout = NULL;
  if(mpi.mpiid == 0)
  {
    std::string outputname = simname + ".out";
    dnsout = std::fopen(outputname.c_str(), "a");
    std::setvbuf(dnsout, NULL, _IOLBF, 1024);
    std::fprintf(dnsout, "%8s %11s %10s %11s %8s %8s %11s %16s %16s %16s\n",
      "ITER", "TIME", "CPUDT", "DT", "CFL", "DNUM", "DIV", "MOM", "TKE", "MASS");
  }

  // set the boundary conditions
  boundary.exec();

  // set the initial cfl and dn
  cfl = advec.getcfl(timeloop.dt);
  dn  = diff.getdn(timeloop.dt);

  // print the initial information
  if(timeloop.docheck() && !timeloop.insubstep())
  {
    iter    = timeloop.iteration;
    time    = timeloop.time;
    cputime = 0;
    dt      = timeloop.dt;
    div     = pres.check();
    mom     = fields.checkmom();
    tke     = fields.checktke();
    mass    = fields.checkmass();

    // write the output to file
    if(mpi.mpiid == 0)
      std::fprintf(dnsout, "%8d %11.3E %10.4f %11.3E %8.4f %8.4f %11.3E %16.8E %16.8E %16.8E\n",
        iter, time, cputime, dt, cfl, dn, div, mom, tke, mass);
    }

  // catch the start time for the first iteration
  start = mpi.gettime();

  // start the time loop
  while(true)
  {
    // determine the time step
    if(!timeloop.insubstep())
    {
      cfl = advec.getcfl(timeloop.dt);
      dn  = diff.getdn(timeloop.dt);
      timeloop.settimestep(cfl, dn);
    }

    // advection
    advec.exec();
    // diffusion
    diff.exec();
    // large scale forcings
    force.exec(timeloop.getsubdt());
    // buoyancy
    buoyancy.exec();
    // buffer
    buffer.exec();

    // pressure
    pres.exec(timeloop.getsubdt());
    if(timeloop.dosave() && !timeloop.insubstep())
      fields.p->save(timeloop.iteration, fields.tmp1->data, fields.tmp2->data);

    if(timeloop.dostats() && !timeloop.insubstep())
    {
      stats.exec(timeloop.iteration, timeloop.time);
      cross.exec(timeloop.iteration);
    }

    // exit the simulation when the runtime has been hit after the pressure calculation
    if(!timeloop.loop)
      break;

    /*
    // PROGNOSTIC MODE
    // integrate in time
    timeloop.exec();

    // step the time step
    if(!timeloop.insubstep())
      timeloop.timestep();

    // save the fields
    if(timeloop.dosave() && !timeloop.insubstep())
    {
      timeloop.save(timeloop.iteration);
      fields.save  (timeloop.iteration);
    }
    // END PROGNOSTIC MODE
    */

    // DIAGNOSTIC MODE
    // step to the next time step
    timeloop.postprocstep();

    // if simulation is done break
    if(!timeloop.loop)
      break;

    // load the data
    if(timeloop.load(timeloop.iteration))
      return 1;
    if(fields.load(timeloop.iteration))
      return 1;
    // END DIAGNOSTIC MODE

    // boundary conditions
    boundary.exec();

    if(timeloop.docheck() && !timeloop.insubstep())
    {
      iter    = timeloop.iteration;
      time    = timeloop.time;
      dt      = timeloop.dt;
      div     = pres.check();
      mom     = fields.checkmom();
      tke     = fields.checktke();
      mass    = fields.checkmass();

      end     = mpi.gettime();
      cputime = end - start;
      start   = end;

      // write the output to file
      if(mpi.mpiid == 0)
        std::fprintf(dnsout, "%8d %11.3E %10.4f %11.3E %8.4f %8.4f %11.3E %16.8E %16.8E %16.8E\n",
          iter, time, cputime, dt, cfl, dn, div, mom, tke, mass);
    }
  }

  // close the output file
  if(mpi.mpiid == 0)
    std::fclose(dnsout);
  
  return 0;
}