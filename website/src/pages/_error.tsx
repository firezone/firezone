// TODO: This error layout doesn't seem to be applied...

import "@/app/globals.css";
import { Source_Sans_Pro } from "next/font/google";
const source_sans_pro = Source_Sans_Pro({
  subsets: ["latin"],
  weight: ["200", "300", "400", "600", "700", "900"],
});

export default function Error({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className={source_sans_pro.className}>{children}</body>
    </html>
  );
}
