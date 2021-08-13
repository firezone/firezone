$NetBSD: patch-cxx_cursesf.h,v 1.1 2011/02/28 11:02:46 adam Exp $

--- c++/cursesf.h.orig	2011-02-28 09:23:33.000000000 +0000
+++ c++/cursesf.h
@@ -677,7 +677,7 @@ protected:
   }

 public:
-  NCursesUserForm (NCursesFormField Fields[],
+  NCursesUserForm (NCursesFormField *Fields[],
 		   const T* p_UserData = STATIC_CAST(T*)(0),
 		   bool with_frame=FALSE,
 		   bool autoDelete_Fields=FALSE)
@@ -686,7 +686,7 @@ public:
 	set_user (const_cast<void *>(p_UserData));
   };

-  NCursesUserForm (NCursesFormField Fields[],
+  NCursesUserForm (NCursesFormField *Fields[],
 		   int nlines,
 		   int ncols,
 		   int begin_y = 0,
