
// -*-c++-*-
/* $Id$ */

#ifndef _DSDC_SIGNAL_H_
#define _DSDC_SIGNAL_H_

#ifndef SIGNAL
# define DSDC_SIGNAL(cb,...) (*cb)(__VA_ARGS__)
#else
# define DSDC_SIGNAL(...) SIGNAL(__VA_ARGS__)
#endif

#endif /* _DSDC_SIGNAL_H_ */
