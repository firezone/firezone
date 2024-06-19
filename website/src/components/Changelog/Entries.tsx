export default function Entries({ children }: { children: React.ReactNode }) {
  return (
    <table className="w-full text-left">
      <thead className="text-neutral-800 bg-neutral-100 uppercase">
        <tr>
          <th
            scope="col"
            className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
          >
            Version
          </th>
          <th
            scope="col"
            className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
          >
            Date
          </th>
          <th
            scope="col"
            className="px-2 py-1 sm:px-3 sm:py-1.5 md:px-4 md:py-2 lg:px-6 lg:py-3"
          >
            Description
          </th>
        </tr>
      </thead>
      <tbody>{children}</tbody>
    </table>
  );
}
