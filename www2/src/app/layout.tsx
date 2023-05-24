import '@/app/globals.css'
import Navbar from '@/components/Navbar'
import { Source_Sans_Pro } from 'next/font/google'

const source_sans_pro = Source_Sans_Pro({
  subsets: ['latin'],
  weight: ['200', '300', '400', '600', '700', '900'],
})

export const metadata = {
  title: 'Create Next App',
  description: 'Generated by create next app',
}

export default function Layout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <body className={source_sans_pro.className}>
      <Navbar/>
      {children}
      </body>
    </html>
  )
}
