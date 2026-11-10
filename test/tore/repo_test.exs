defmodule Tore.RepoTest do
  use Tore.DataCase, async: true

  import Ecto.Query

  alias Tore.Capture.{UploadedImage, Uploads}
  alias Tore.Household.HouseholdSchema

  setup do
    a = scope_fixture(household_fixture())
    b = scope_fixture(household_fixture())
    {:ok, _} = Uploads.record(a, "hash-a", "run-a", "receipt")
    {:ok, _} = Uploads.record(b, "hash-b", "run-b", "receipt")
    %{a: a, b: b, opts: [household_id: a.household_id]}
  end

  defp hashes(query, opts), do: query |> Repo.all(opts) |> Enum.sort()

  describe "without a household_id" do
    test "a query on a household table raises" do
      assert_raise ArgumentError, ~r/uploaded_images/, fn -> Repo.all(UploadedImage) end
      assert_raise ArgumentError, fn -> Repo.get_by(UploadedImage, content_hash: "hash-a") end
      assert_raise ArgumentError, fn -> Repo.delete_all(UploadedImage) end
      assert_raise ArgumentError, fn -> Repo.all(from(u in "uploaded_images", select: u.id)) end
    end

    test "a household table anywhere in the query counts" do
      images = from(u in UploadedImage, select: u.household_id)

      for query <- [
            from(h in HouseholdSchema, join: u in UploadedImage, on: u.household_id == h.id),
            from(h in subquery(from(u in UploadedImage, select: %{id: u.id}))),
            from(h in HouseholdSchema, where: h.id in subquery(images)),
            from(h in HouseholdSchema,
              where: exists(from(u in UploadedImage, where: u.household_id == parent_as(:h).id))
            )
            |> from(as: :h),
            from(h in HouseholdSchema, select: h.id) |> union_all(^images),
            from(h in HouseholdSchema)
            |> with_cte("u", as: ^from(u in UploadedImage, select: %{id: u.id}))
          ] do
        assert_raise ArgumentError, fn -> Repo.all(query) end
      end
    end

    test "tables outside the household list need no scope" do
      assert Repo.all(HouseholdSchema) != []
    end
  end

  describe "with a household_id" do
    test "the root is kept to that household", %{a: a, b: b} do
      assert [%{content_hash: "hash-a"}] = Repo.all(UploadedImage, household_id: a.household_id)
      assert [%{content_hash: "hash-b"}] = Repo.all(UploadedImage, household_id: b.household_id)

      assert Repo.get_by(UploadedImage, [content_hash: "hash-a"], household_id: b.household_id) ==
               nil

      assert Repo.update_all(UploadedImage, [set: [kind: "x"]], household_id: b.household_id) ==
               {1, nil}
    end

    test "counts with distinct or a limit, which Ecto wraps in a subquery", %{opts: opts} do
      assert Repo.aggregate(from(u in UploadedImage, distinct: true), :count, opts) == 1
      assert Repo.aggregate(from(u in UploadedImage, limit: 10), :count, opts) == 1
    end

    test "subqueries, unions and CTEs are filtered too", %{opts: opts} do
      hash = from(u in UploadedImage, select: u.content_hash)

      assert hashes(
               from(s in subquery(from(u in UploadedImage, select: %{h: u.content_hash})),
                 select: s.h
               ),
               opts
             ) ==
               ["hash-a"]

      assert hashes(hash |> union_all(^hash), opts) == ["hash-a", "hash-a"]

      assert hashes(
               from(h in HouseholdSchema,
                 where: h.id in subquery(from(u in UploadedImage, select: u.household_id)),
                 select: h.id
               ),
               opts
             ) == [opts[:household_id]]

      cte = from(u in UploadedImage, select: %{h: u.content_hash})
      with_cte = from(c in "c", select: c.h) |> with_cte("c", as: ^cte)
      assert hashes(with_cte, opts) == ["hash-a"]
    end

    test "a join is filtered in its on, so a left join keeps its rows", %{a: a, b: b, opts: opts} do
      joined =
        from(h in HouseholdSchema,
          left_join: u in UploadedImage,
          on: u.household_id == h.id,
          where: h.id in ^[a.household_id, b.household_id],
          select: {h.id, u.content_hash}
        )

      assert hashes(joined, opts) == [{a.household_id, "hash-a"}, {b.household_id, nil}]
    end
  end
end
