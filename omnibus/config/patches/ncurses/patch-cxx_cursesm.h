$NetBSD: patch-cxx_cursesm.h,v 1.1 2011/02/28 11:02:46 adam Exp $

--- c++/cursesm.h.orig	2011-02-28 09:25:22.000000000 +0000
+++ c++/cursesm.h
@@ -635,7 +635,7 @@ protected:
   }

 public:
-  NCursesUserMenu (NCursesMenuItem Items[],
+  NCursesUserMenu (NCursesMenuItem *Items[],
 		   const T* p_UserData = STATIC_CAST(T*)(0),
 		   bool with_frame=FALSE,
 		   bool autoDelete_Items=FALSE)
@@ -644,7 +644,7 @@ public:
 	set_user (const_cast<void *>(p_UserData));
   };

-  NCursesUserMenu (NCursesMenuItem Items[],
+  NCursesUserMenu (NCursesMenuItem *Items[],
 		   int nlines,
 		   int ncols,
 		   int begin_y = 0,
