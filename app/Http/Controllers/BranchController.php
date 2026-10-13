<?php

namespace App\Http\Controllers;

use App\Models\Branch;
use App\Models\Organization;
use App\Support\OrganizationScope;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

class BranchController extends Controller
{
    public function index(Request $request): JsonResponse
    {
        $this->authorizeSubject($request, 'device');
        $organizationId = OrganizationScope::forTenant($request);

        $query = Branch::query()->where('organization_id', $organizationId)->with('head');
        if ($name = OrganizationScope::nameFilter($request)) {
            $query->where('name', 'like', '%'.$name.'%');
        }

        return response()->json(
            $query->orderBy('name')->get()->map(fn (Branch $branch) => $branch->present())->values()
        );
    }

    public function store(Request $request): JsonResponse
    {
        $this->authorizeSubject($request, 'device');
        $organizationId = OrganizationScope::forTenant($request);
        Organization::query()->findOrFail($organizationId)->assertCanAdd('branch');
        $data = $request->validate([
            'name' => [
                'required',
                'string',
                'max:255',
                Rule::unique('branches', 'name')->where('organization_id', $organizationId),
            ],
        ]);

        $branch = Branch::query()->create([
            'organization_id' => $organizationId,
            'name' => $data['name'],
        ]);

        return response()->json($branch->present(), 201);
    }

    public function update(Request $request, Branch $branch): JsonResponse
    {
        $this->authorizeSubject($request, 'device');
        $this->assertSameOrganization($request, $branch->organization_id);
        $data = $request->validate([
            'name' => [
                'required',
                'string',
                'max:255',
                Rule::unique('branches', 'name')->where('organization_id', $branch->organization_id)->ignore($branch->id),
            ],
        ]);

        $branch->update(['name' => $data['name']]);

        return response()->json($branch->fresh()->present());
    }
    

    public function destroy(Request $request, Branch $branch): JsonResponse
    {
        $this->authorizeSubject($request, 'device');
        $this->assertSameOrganization($request, $branch->organization_id);
        $branch->delete();

        return response()->json(['ok' => true]);
    }

    private function assertSameOrganization(Request $request, int $organizationId): void
    {
        abort_unless(OrganizationScope::forTenant($request) === $organizationId, 404);
    }

    private function authorizeSubject(Request $request, string $subject): void
    {
        abort_unless($request->user()?->canManage($subject), 403);
    }
}
