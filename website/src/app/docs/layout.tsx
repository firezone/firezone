import RootLayout from '@/components/RootLayout'
import DocsSidebar from '@/components/DocsSidebar'

export default function Layout({
  children
}: {
  children: React.ReactNode
}) {
  return (
    <RootLayout>
      <DocsSidebar />
      {children}
    </RootLayout>
  )
}
