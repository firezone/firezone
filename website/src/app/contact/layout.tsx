export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <div className="pt-14 flex flex-col">
      <div className="px-4 mx-auto max-w-screen-2xl w-full lg:px-6">
        {children}
      </div>
    </div>
  );
}
