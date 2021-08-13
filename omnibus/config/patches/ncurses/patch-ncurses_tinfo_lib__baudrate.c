$NetBSD: patch-ncurses_tinfo_lib__baudrate.c,v 1.1 2014/05/11 16:55:17 rodent Exp $

sys/ttydev.h doesn't exist in OpenBSD 5.5

--- ncurses/tinfo/lib_baudrate.c.orig	Sun Dec 19 01:50:50 2010
+++ ncurses/tinfo/lib_baudrate.c
@@ -39,7 +39,7 @@

 #include <curses.priv.h>
 #include <termcap.h>		/* ospeed */
-#if defined(__FreeBSD__)
+#if defined(__FreeBSD__) || defined(__OpenBSD__)
 #include <sys/param.h>
 #endif

@@ -49,7 +49,7 @@
  * of the indices up to B115200 fit nicely in a 'short', allowing us to retain
  * ospeed's type for compatibility.
  */
-#if (defined(__FreeBSD__) && (__FreeBSD_version < 700000)) || defined(__NetBSD__) || defined(__OpenBSD__)
+#if (defined(__FreeBSD__) && (__FreeBSD_version < 700000)) || defined(__NetBSD__) || (defined(__OpenBSD__) && (OpenBSD < 201405))
 #undef B0
 #undef B50
 #undef B75
